CREATE OR REPLACE FUNCTION public.get_my_accessible_events()
RETURNS SETOF public.events
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT e.*
  FROM public.events AS e
  WHERE e.status = 'published'
    AND e.visibility <> 'hidden'

  UNION

  SELECT e.*
  FROM public.events AS e
  JOIN public.event_rsvps AS er
    ON er.event_id = e.id
  WHERE auth.uid() IS NOT NULL
    AND er.user_id = auth.uid()
    AND er.status = 'approved'

  ORDER BY starts_at ASC;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_accessible_events() TO anon, authenticated;
