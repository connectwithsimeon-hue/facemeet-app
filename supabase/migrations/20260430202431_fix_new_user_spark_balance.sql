-- Fix handle_new_user() trigger to explicitly set spark_balance = 3 on new registration
-- This ensures every new user starts with exactly 3 free sparks regardless of column defaults

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
