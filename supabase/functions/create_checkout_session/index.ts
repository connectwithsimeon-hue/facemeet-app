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

const allowedProducts: Record<
  string,
  { priceId: string; discountedPriceId?: string; mode: "payment" | "subscription" }
> = {
  bundle_3: {
    priceId: "price_1Tbrny4uLYCTFXBPsm8MgOOD",
    discountedPriceId: "price_1TbrnV4uLYCTFXBPgsfT5kbP",
    mode: "payment",
  },
  bundle_10: {
    priceId: "price_1Tbrnt4uLYCTFXBPZNBRBMcL",
    discountedPriceId: "price_1Tbrnc4uLYCTFXBPZrcGzANz",
    mode: "payment",
  },
  bundle_25: {
    priceId: "price_1Tbrnn4uLYCTFXBPOXgO3Luy",
    discountedPriceId: "price_1Tbrni4uLYCTFXBPtxbQoUDp",
    mode: "payment",
  },
  spark_plus: {
    priceId: "price_1TbroA4uLYCTFXBPvuMq8qsA",
    mode: "subscription",
  },
  gold: {
    priceId: "price_1Tbro44uLYCTFXBPibjCRtB3",
    mode: "subscription",
  },
};

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function sanitizeStripeError(err: unknown): { code: string; message: string } {
  const stripeError = err as {
    code?: string;
    type?: string;
    message?: string;
    raw?: { code?: string; type?: string; message?: string };
  };

  return {
    code: stripeError.code ?? stripeError.raw?.code ?? stripeError.type ??
      stripeError.raw?.type ?? "unknown_stripe_error",
    message: stripeError.message ?? stripeError.raw?.message ??
      "Stripe checkout session creation failed",
  };
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authorization = req.headers.get("authorization") ?? "";
    const token = authorization.replace(/^Bearer\s+/i, "").trim();
    if (!token) {
      console.log("create_checkout_session: authenticated user found=no");
      return new Response(
        JSON.stringify({ error: "Missing authorization token" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const { data: authData, error: authError } = await supabase.auth.getUser(token);
    if (authError || !authData.user) {
      console.log("create_checkout_session: authenticated user found=no");
      return new Response(
        JSON.stringify({ error: "Invalid authorization token" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    console.log("create_checkout_session: authenticated user found=yes");
    const user_id = authData.user.id;
    const { price_id, product_type } = await req.json();
    console.log(`STRIPE CHECKOUT: product_type received=${product_type ?? "missing"}`);

    if (!product_type) {
      return new Response(
        JSON.stringify({ error: "Missing required field: product_type" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (price_id) {
      console.log("STRIPE CHECKOUT: rejected client price_id=yes");
      return new Response(
        JSON.stringify({ error: "Client price_id is not allowed" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    const productConfig = allowedProducts[product_type];
    if (!productConfig) {
      console.log("create_checkout_session: mapped price ID present=no");
      return new Response(
        JSON.stringify({ error: "Unsupported product type" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    console.log("create_checkout_session: mapped price ID present=yes");
    console.log(`create_checkout_session: checkout mode=${productConfig.mode}`);

    const isSubscription = productConfig.mode === "subscription";

    // Look up existing stripe_customer_id from payments table
    const { data: existingPayment } = await supabase
      .from("payments")
      .select("stripe_customer_id")
      .eq("user_id", user_id)
      .not("stripe_customer_id", "is", null)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    const existingCustomerId = existingPayment?.stripe_customer_id ?? null;

    // Fetch user details for pre-filling Stripe checkout and server-side discounts.
    const { data: userData } = await supabase
      .from("users")
      .select("email, stripe_customer_id, subscription_tier")
      .eq("id", user_id)
      .single();

    // Prefer stripe_customer_id from users table if available
    const stripeCustomerId = userData?.stripe_customer_id ?? existingCustomerId ?? null;
    const customerEmail = userData?.email ?? undefined;
    const subscriptionTier = userData?.subscription_tier ?? "free";
    const bundleDiscountEligible = !isSubscription &&
      (subscriptionTier === "spark_plus" || subscriptionTier === "gold");
    const selectedPriceId = bundleDiscountEligible && productConfig.discountedPriceId
      ? productConfig.discountedPriceId
      : productConfig.priceId;

    console.log(`STRIPE CHECKOUT: price selected server-side=${selectedPriceId ? "yes" : "no"}`);
    console.log(`STRIPE CHECKOUT: tier found=${userData?.subscription_tier ? "yes" : "no"}`);
    console.log(`STRIPE CHECKOUT: discount eligible=${bundleDiscountEligible ? "yes" : "no"}`);
    console.log(`STRIPE CHECKOUT: discounted price selected=${selectedPriceId === productConfig.discountedPriceId ? "yes" : "no"}`);
    console.log(`STRIPE CHECKOUT: product type=${product_type}`);

    // Build session params
    const sessionParams: any = {
      mode: isSubscription ? "subscription" : "payment",
      line_items: [
        {
          price: selectedPriceId,
          quantity: 1,
        },
      ],
      metadata: {
        user_id,
        product_type,
      },
      success_url: "https://app.facemeet.app/payment-success.html",
      cancel_url: "https://app.facemeet.app/payment-cancelled.html",
    };

    // For subscriptions, also embed metadata on the subscription object itself
    // so invoice.payment_succeeded events can look up user_id and product_type
    if (isSubscription) {
      sessionParams.subscription_data = {
        metadata: {
          user_id,
          product_type,
        },
      };
    } else {
      sessionParams.payment_intent_data = {
        setup_future_usage: "off_session",
      };
    }

    if (stripeCustomerId) {
      // Returning customer — pass existing Customer so saved card loads automatically
      sessionParams.customer = stripeCustomerId;
    } else if (isSubscription) {
      // Subscription mode: customer_creation is not supported — pass email only
      // Stripe will auto-create a Customer for subscriptions
      if (customerEmail) {
        sessionParams.customer_email = customerEmail;
      }
    } else {
      // Payment mode: explicitly create a Customer and save card for future use
      sessionParams.customer_creation = "always";
      if (customerEmail) {
        sessionParams.customer_email = customerEmail;
      }
    }

    console.log("create_checkout_session: Stripe session create started");
    let session;
    try {
      session = await stripe.checkout.sessions.create(sessionParams);
      console.log("create_checkout_session: Stripe session create success");
    } catch (stripeErr) {
      const sanitized = sanitizeStripeError(stripeErr);
      console.error(
        `create_checkout_session: Stripe session create failure; code=${sanitized.code}; message=${sanitized.message}`,
      );
      return new Response(
        JSON.stringify({
          error: "checkout_session_failed",
          message: "Checkout could not start for this product.",
          stripe_code: sanitized.code,
        }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } },
      );
    }

    return new Response(
      JSON.stringify({
        url: session.url,
        session_id: session.id,
        stripe_customer_id: session.customer,
      }),
      { headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err) {
    console.error(
      `create_checkout_session error: ${err instanceof Error ? err.message : "Unknown checkout error"}`,
    );
    return new Response(
      JSON.stringify({
        error: "checkout_session_failed",
        message: "Checkout could not start for this product.",
        stripe_code: "unexpected_checkout_error",
      }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
