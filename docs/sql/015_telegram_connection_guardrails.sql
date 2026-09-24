-- Make cross-role Telegram group connection attempts fail safely instead of
-- surfacing a unique-constraint workflow error. Apply after 014.

SET search_path TO ticket_cluster, public;

CREATE OR REPLACE FUNCTION consume_telegram_setup_code(
  p_code text,
  p_role text,
  p_chat_id bigint,
  p_chat_type text,
  p_chat_title text,
  p_actor_user_id bigint,
  p_actor_name text
)
RETURNS text
LANGUAGE plpgsql
SET search_path = ticket_cluster, public
AS $$
DECLARE v_code telegram_setup_codes%ROWTYPE;
BEGIN
  IF p_role NOT IN ('review', 'engineering') THEN RETURN 'invalid_role'; END IF;
  IF p_chat_type NOT IN ('group', 'supergroup', 'channel') THEN RETURN 'group_required'; END IF;

  PERFORM pg_advisory_xact_lock(p_chat_id);

  IF EXISTS (
    SELECT 1 FROM telegram_connections
    WHERE chat_id = p_chat_id AND role <> p_role AND active
  ) THEN
    RETURN 'chat_already_connected';
  END IF;

  SELECT * INTO v_code
  FROM telegram_setup_codes
  WHERE role = p_role
    AND code_hash = digest(upper(btrim(p_code)), 'sha256')
  FOR UPDATE;

  IF NOT FOUND OR v_code.used_at IS NOT NULL OR v_code.expires_at <= now() THEN
    RETURN 'invalid_or_expired_code';
  END IF;

  INSERT INTO telegram_connections (role, chat_id, chat_type, title, connected_by_user_id)
  VALUES (p_role, p_chat_id, p_chat_type, nullif(p_chat_title, ''), p_actor_user_id)
  ON CONFLICT (role) DO UPDATE
    SET chat_id = EXCLUDED.chat_id,
        chat_type = EXCLUDED.chat_type,
        title = EXCLUDED.title,
        active = true,
        connected_by_user_id = EXCLUDED.connected_by_user_id,
        updated_at = now();

  IF p_role = 'review' THEN
    INSERT INTO authorized_telegram_approvers (telegram_user_id, display_name)
    VALUES (p_actor_user_id, nullif(p_actor_name, ''))
    ON CONFLICT (telegram_user_id) DO UPDATE
      SET display_name = coalesce(EXCLUDED.display_name, authorized_telegram_approvers.display_name),
          active = true,
          revoked_at = NULL;
  END IF;

  UPDATE telegram_setup_codes
  SET used_at = now(), used_by_user_id = p_actor_user_id, used_in_chat_id = p_chat_id
  WHERE id = v_code.id;
  RETURN 'connected';
END;
$$;
