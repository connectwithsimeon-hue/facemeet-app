import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import Stripe from "https://esm.sh/stripe@12.0.0?target=deno";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY")!, {
  apiVersion: "2023-10-16",
  httpClient: Stripe.createFetchHttpClient(),
});

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
);

// Spark replenishment per tier per renewal cycle
// Free: no recurring replenishment; starter Sparks are granted once only.
// Spark+: +2 per day (handled client-side via spark_last_replenished_at)
// Gold: +5 per day (handled client-side via spark_last_replenished_at)
const SPARK_ALLOWANCE: Record<string, number> = {
  spark_plus: 2,
  gold: 5,
};

// Maximum spark balance from tier replenishment only.
// Bundles always add regardless of this cap.
const SPARK_REPLENISHMENT_CAP = 50;

/**
 * Add sparks from tier replenishment, capped at SPARK_REPLENISHMENT_CAP.
 * If current balance is already at or above cap, no sparks are added.
 * If adding would exceed cap, only add enough to reach exactly cap.
 */
function calculateReplenishedBalance(currentBalance: number, allowance: number): number {
  if (currentBalance >= SPARK_REPLENISHMENT_CAP) {
    console.log(`Replenishment skipped: balance=${currentBalance} already at cap=${SPARK_REPLENISHMENT_CAP}`);
    return currentBalance;
  }
  const room = SPARK_REPLENISHMENT_CAP - currentBalance;
  const toAdd = Math.min(allowance, room);
  const newBalance = currentBalance + toAdd;
  console.log(`Replenishment: adding ${toAdd} (of ${allowance}) sparks. Current: ${currentBalance}, New: ${newBalance}, Cap: ${SPARK_REPLENISHMENT_CAP}`);
  return newBalance;
}

serve(async (req) => {
  const signature = req.headers.get("stripe-signature")!;
  const body = await req.text();

  let event;
  try {
    event = await stripe.webhooks.constructEventAsync(
      body,
      signature,
      Deno.env.get("STRIPE_WEBHOOK_SECRET")!
    );
  } catch (err) {
    console.error("Webhook signature verification failed:", err.message);
    return new Response(`Webhook Error: ${err.message}`, { status: 400 });
  }

  console.log(`Processing event: ${event.type}`);

  const session = event.data.object as any;

  switch (event.type) {

    case "checkout.session.completed": {
      const userId = session.metadata?.user_id;
      const productType = session.metadata?.product_type;
      const stripeCustomerId = session.customer;
      const paymentRef = session.payment_intent ?? session.subscription ?? session.id;

      console.log(`checkout.session.completed: userId=${userId}, productType=${productType}, mode=${session.mode}`);

      if (!userId || !productType) {
        console.error("Missing userId or productType in session metadata");
        break;
      }

      // Insert payment record
      const { error: paymentInsertError } = await supabase.from("payments").insert({
        user_id: userId,
        stripe_payment_intent_id: paymentRef,
        stripe_customer_id: stripeCustomerId,
        product_type: productType,
        amount_cents: session.amount_total,
        status: "succeeded",
      });
      if (paymentInsertError) {
        console.error("Failed to insert payment record:", paymentInsertError);
      }

      // Save stripe_customer_id to users table
      if (stripeCustomerId) {
        await supabase.from("users").update({
          stripe_customer_id: stripeCustomerId,
        }).eq("id", userId);
      }

      // Handle subscription tiers
      if (productType === "spark_plus" || productType === "gold") {
        const allowance = SPARK_ALLOWANCE[productType];

        const { data: userData, error: fetchError } = await supabase
          .from("users")
          .select("spark_balance")
          .eq("id", userId)
          .single();

        if (fetchError) {
          console.error("Failed to fetch user spark_balance:", fetchError);
        }

        const currentBalance = (userData?.spark_balance as number) ?? 0;
        // First subscription purchase: apply cap
        const newBalance = calculateReplenishedBalance(currentBalance, allowance);

        const { error: updateError } = await supabase.from("users").update({
          subscription_tier: productType,
          subscription_expires_at: new Date(
            Date.now() + 30 * 24 * 60 * 60 * 1000
          ).toISOString(),
          spark_balance: newBalance,
          spark_last_replenished_at: new Date().toISOString(),
        }).eq("id", userId);

        if (updateError) {
          console.error(`Failed to update user subscription (${productType}):`, updateError);
        } else {
          console.log(`Successfully updated user ${userId} to ${productType} with spark_balance=${newBalance}`);
        }

        // Tag the Stripe subscription with metadata
        if (session.subscription) {
          try {
            await stripe.subscriptions.update(session.subscription, {
              metadata: { user_id: userId, product_type: productType },
            });
            console.log(`Tagged subscription ${session.subscription} with metadata`);
          } catch (e) {
            console.error("Failed to tag subscription metadata:", e);
          }
        }
      }

      // Handle spark bundles (one-time purchases) — ALWAYS add, no cap
      const bundleMap: Record<string, number> = {
        bundle_3: 3,
        bundle_10: 10,
        bundle_25: 25,
      };

      if (bundleMap[productType] !== undefined) {
        const paymentIntentId = typeof session.payment_intent === "string"
          ? session.payment_intent
          : session.payment_intent?.id;
        console.log(`STRIPE WEBHOOK: bundle payment intent found ${paymentIntentId ? "yes" : "no"}`);

        if (paymentIntentId) {
          try {
            const paymentIntent = await stripe.paymentIntents.retrieve(paymentIntentId);
            const paymentMethod = typeof paymentIntent.payment_method === "string"
              ? paymentIntent.payment_method
              : paymentIntent.payment_method?.id;
            const customer = typeof paymentIntent.customer === "string"
              ? paymentIntent.customer
              : paymentIntent.customer?.id;

            console.log(`STRIPE WEBHOOK: payment method present ${paymentMethod ? "yes" : "no"}`);

            if (customer && paymentMethod) {
              await stripe.customers.update(customer, {
                invoice_settings: {
                  default_payment_method: paymentMethod,
                },
              });
              console.log("STRIPE WEBHOOK: default payment method set yes");
            } else {
              console.log("STRIPE WEBHOOK: default payment method set no");
            }
          } catch (e) {
            console.error(
              `STRIPE WEBHOOK: default payment method set no; error=${e instanceof Error ? e.name : "unknown_error"}`,
            );
          }
        } else {
          console.log("STRIPE WEBHOOK: payment method present no");
          console.log("STRIPE WEBHOOK: default payment method set no");
        }

        const { data: user, error: fetchError } = await supabase
          .from("users")
          .select("spark_balance")
          .eq("id", userId)
          .single();

        if (fetchError) {
          console.error("Failed to fetch user for bundle:", fetchError);
        }

        const currentBalance = (user?.spark_balance as number) ?? 0;
        // Bundles ALWAYS add regardless of cap
        const newBalance = currentBalance + bundleMap[productType];

        console.log(`Bundle purchase: adding ${bundleMap[productType]} sparks (no cap). Current: ${currentBalance}, New: ${newBalance}`);

        const { error: updateError } = await supabase.from("users").update({
          spark_balance: newBalance,
        }).eq("id", userId);

        if (updateError) {
          console.error("Failed to update spark_balance for bundle:", updateError);
        } else {
          console.log(`Successfully credited bundle sparks to user ${userId}, new balance=${newBalance}`);
        }
      }

      break;
    }

    case "customer.subscription.deleted": {
      const customerId = session.customer;
      console.log(`customer.subscription.deleted: customerId=${customerId}`);

      const { data: userByCustomer } = await supabase
        .from("users")
        .select("id")
        .eq("stripe_customer_id", customerId)
        .maybeSingle();

      const userId = userByCustomer?.id;

      if (userId) {
        await supabase.from("users").update({
          subscription_tier: "free",
          subscription_expires_at: null,
        }).eq("id", userId);
        console.log(`Downgraded user ${userId} to free tier`);
      } else {
        const { data: payment } = await supabase
          .from("payments")
          .select("user_id")
          .eq("stripe_customer_id", customerId)
          .order("created_at", { ascending: false })
          .limit(1)
          .maybeSingle();

        if (payment?.user_id) {
          await supabase.from("users").update({
            subscription_tier: "free",
            subscription_expires_at: null,
          }).eq("id", payment.user_id);
          console.log(`Downgraded user ${payment.user_id} to free tier (via payments table)`);
        } else {
          console.error(`Could not find user for customerId=${customerId} on subscription deletion`);
        }
      }
      break;
    }

    case "invoice.payment_succeeded": {
      const customerId = session.customer;
      const subscriptionId = session.subscription;
      console.log(`invoice.payment_succeeded: customerId=${customerId}, subscriptionId=${subscriptionId}`);

      // Skip the very first invoice — it's already handled by checkout.session.completed
      const billingReason = session.billing_reason as string;
      console.log(`billing_reason=${billingReason}`);

      if (billingReason === "subscription_create") {
        console.log("Skipping invoice.payment_succeeded for subscription_create (handled by checkout.session.completed)");
        break;
      }

      // Find user
      let userId: string | null = null;
      let productType: string | null = null;

      const { data: userByCustomer } = await supabase
        .from("users")
        .select("id, subscription_tier")
        .eq("stripe_customer_id", customerId)
        .maybeSingle();

      if (userByCustomer) {
        userId = userByCustomer.id;
        productType = userByCustomer.subscription_tier;
        console.log(`Found user ${userId} with tier ${productType} via stripe_customer_id`);
      }

      if (!userId) {
        const { data: payment } = await supabase
          .from("payments")
          .select("user_id, product_type")
          .eq("stripe_customer_id", customerId)
          .in("product_type", ["spark_plus", "gold"])
          .order("created_at", { ascending: false })
          .limit(1)
          .maybeSingle();

        if (payment) {
          userId = payment.user_id;
          productType = payment.product_type;
          console.log(`Found user ${userId} with product_type ${productType} via payments table`);
        }
      }

      if (!userId && subscriptionId) {
        try {
          const subscription = await stripe.subscriptions.retrieve(subscriptionId);
          const subUserId = subscription.metadata?.user_id;
          const subProductType = subscription.metadata?.product_type;
          if (subUserId) {
            userId = subUserId;
            productType = subProductType ?? productType;
            console.log(`Found user ${userId} with product_type ${productType} via subscription metadata`);
          }
        } catch (e) {
          console.error("Failed to retrieve subscription metadata:", e);
        }
      }

      if (!userId) {
        console.error(`Could not find user for customerId=${customerId} on invoice.payment_succeeded`);
        break;
      }

      // Extend subscription expiry
      await supabase.from("users").update({
        subscription_expires_at: new Date(
          Date.now() + 30 * 24 * 60 * 60 * 1000
        ).toISOString(),
      }).eq("id", userId);

      // Credit daily spark allowance on renewal — apply 50-cap
      if (productType && SPARK_ALLOWANCE[productType] !== undefined) {
        const allowance = SPARK_ALLOWANCE[productType];

        const { data: userData } = await supabase
          .from("users")
          .select("spark_balance")
          .eq("id", userId)
          .single();

        const currentBalance = (userData?.spark_balance as number) ?? 0;
        const newBalance = calculateReplenishedBalance(currentBalance, allowance);

        console.log(`Renewal: crediting sparks for ${productType}. Current: ${currentBalance}, New: ${newBalance}`);

        await supabase.from("users").update({
          spark_balance: newBalance,
          spark_last_replenished_at: new Date().toISOString(),
        }).eq("id", userId);
      }

      break;
    }

    case "invoice.payment_failed": {
      const customerId = session.customer;
      console.log(`invoice.payment_failed: customerId=${customerId}`);

      const { data: userByCustomer } = await supabase
        .from("users")
        .select("id")
        .eq("stripe_customer_id", customerId)
        .maybeSingle();

      const userId = userByCustomer?.id;

      if (userId) {
        await supabase.from("users").update({
          subscription_tier: "free",
        }).eq("id", userId);
        console.log(`Downgraded user ${userId} to free on payment failure`);
      } else {
        const { data: payment } = await supabase
          .from("payments")
          .select("user_id")
          .eq("stripe_customer_id", customerId)
          .order("created_at", { ascending: false })
          .limit(1)
          .maybeSingle();

        if (payment?.user_id) {
          await supabase.from("users").update({
            subscription_tier: "free",
          }).eq("id", payment.user_id);
          console.log(`Downgraded user ${payment.user_id} to free on payment failure (via payments table)`);
        }
      }
      break;
    }
  }

  return new Response(JSON.stringify({ received: true }), {
    headers: { "Content-Type": "application/json" },
  });
});
