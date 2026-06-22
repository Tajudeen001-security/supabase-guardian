-- Run this in Supabase Dashboard → SQL Editor for project fwjxhozxlucaywpavznu.
-- Fixes group chat: ensures the schema + RLS policies match what the app sends.
-- The app inserts { group_id, sender_id, content, message_type }.
-- Earlier patches created conflicting policies referencing a non-existent
-- user_id column, which silently blocked INSERTs. This restores the correct
-- sender_id-based policies.

-- 1) Ensure columns exist
ALTER TABLE public.group_messages
  ADD COLUMN IF NOT EXISTS sender_id uuid,
  ADD COLUMN IF NOT EXISTS message_type text NOT NULL DEFAULT 'text',
  ADD COLUMN IF NOT EXISTS updated_at timestamptz NOT NULL DEFAULT now();

-- Backfill sender_id from any legacy user_id column
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'group_messages' AND column_name = 'user_id'
  ) THEN
    EXECUTE 'UPDATE public.group_messages SET sender_id = user_id WHERE sender_id IS NULL';
  END IF;
END $$;

ALTER TABLE public.group_messages ALTER COLUMN sender_id SET NOT NULL;

-- 2) RLS + grants
ALTER TABLE public.group_messages ENABLE ROW LEVEL SECURITY;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.group_messages TO authenticated;
GRANT ALL ON public.group_messages TO service_role;

-- 3) Drop ALL existing policies on group_messages so we start clean
DO $$
DECLARE pol record;
BEGIN
  FOR pol IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'group_messages'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.group_messages', pol.policyname);
  END LOOP;
END $$;

-- 4) Correct policies (all keyed on sender_id)
CREATE POLICY "Members can view group messages"
  ON public.group_messages FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.group_members
      WHERE group_id = group_messages.group_id AND user_id = auth.uid()
    )
  );

CREATE POLICY "Members can send group messages"
  ON public.group_messages FOR INSERT TO authenticated
  WITH CHECK (
    auth.uid() = sender_id
    AND EXISTS (
      SELECT 1 FROM public.group_members
      WHERE group_id = group_messages.group_id AND user_id = auth.uid()
    )
  );

CREATE POLICY "Senders can update own group messages"
  ON public.group_messages FOR UPDATE TO authenticated
  USING (auth.uid() = sender_id);

CREATE POLICY "Senders can delete own group messages"
  ON public.group_messages FOR DELETE TO authenticated
  USING (auth.uid() = sender_id);

-- 5) Make sure realtime is enabled
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime'
      AND schemaname = 'public'
      AND tablename = 'group_messages'
  ) THEN
    EXECUTE 'ALTER PUBLICATION supabase_realtime ADD TABLE public.group_messages';
  END IF;
END $$;
