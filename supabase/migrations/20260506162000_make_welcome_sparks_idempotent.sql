-- Make new-user welcome Sparks idempotent.
-- New users get exactly 3 Sparks once, and spark_last_replenished_at is set
-- immediately so the client weekly replenishment does not add another 3.

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
BEGIN
    INSERT INTO public.users (
        id,
        email,
        first_name,
        spark_balance,
        spark_last_replenished_at
    )
    VALUES (
        NEW.id,
        NEW.email,
        COALESCE(NEW.raw_user_meta_data->>'first_name', ''),
        3,
        NOW()
    )
    ON CONFLICT (id) DO UPDATE
    SET
        spark_balance = COALESCE(public.users.spark_balance, 3),
        spark_last_replenished_at = COALESCE(
            public.users.spark_last_replenished_at,
            NOW()
        );
    RETURN NEW;
END;
$$;
