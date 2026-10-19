-- =====================================================================
-- BEM Ledger — donor import (CSV). The app parses the file and maps the
-- columns; this function finds existing donors and creates or updates.
-- p: {rows: [{donor fields...}], mode: 'skip'|'update', dry_run: boolean}
--   Matching, in order: donor_number, email, then name + ZIP
--   (organization name, or first + last name).
--   mode 'skip'   = leave existing donors alone (default)
--   mode 'update' = fill in / overwrite fields that the file provides
-- Returns {created, updated, skipped, errors, results:[{row, action, donor_id, name, message}]}
-- =====================================================================
create or replace function import_donors(p jsonb) returns jsonb
language plpgsql as $$
declare
  r jsonb; i int := 0; v_match donors; v_action text; v_msg text; v_name text; v_saved jsonb;
  v_mode text := coalesce(nullif(p->>'mode',''), 'skip'); v_dry boolean := coalesce((p->>'dry_run')::boolean, false);
  v_results jsonb := '[]'; c_created int := 0; c_updated int := 0; c_skipped int := 0; c_errors int := 0;
  v_seen text[] := '{}'; v_key text; v_type text;
begin
  if jsonb_typeof(p->'rows') <> 'array' then raise exception 'No rows to import'; end if;
  if v_mode not in ('skip','update') then raise exception 'Unknown import mode'; end if;

  for r in select * from jsonb_array_elements(p->'rows') loop
    i := i + 1; v_match := null; v_msg := null;
    -- clean empty strings to null
    r := (select coalesce(jsonb_object_agg(k, v), '{}') from jsonb_each(r) e(k, v)
           where not (jsonb_typeof(v) = 'string' and trim(v #>> '{}') = ''));
    v_type := coalesce(r->>'donor_type', 'individual');
    v_name := case when v_type in ('individual','household')
                   then trim(concat_ws(' ', r->>'first_name', case when r ? 'spouse_name' then '& ' || (r->>'spouse_name') end, r->>'last_name'))
                   else r->>'organization_name' end;

    if coalesce(v_name, '') = '' then
      v_action := 'error'; v_msg := case when v_type in ('individual','household') then 'No first or last name' else 'No organization name' end;
    elsif v_type not in ('individual','household','church','organization','foundation','business') then
      v_action := 'error'; v_msg := 'Unknown donor type "' || v_type || '"';
    elsif coalesce(r->>'receipt_preference','email') not in ('email','mail','none') then
      v_action := 'error'; v_msg := 'Receipt preference must be email, mail or none';
    else
      -- duplicates inside the file itself
      v_key := lower(coalesce(r->>'email', v_name || '|' || coalesce(r->>'postal_code','')));
      if v_key = any(v_seen) then
        v_action := 'skip'; v_msg := 'Same donor appears earlier in the file';
      else
        v_seen := v_seen || v_key;
        if r ? 'donor_number' then
          select * into v_match from donors where donor_number::text = r->>'donor_number';
        end if;
        if v_match.id is null and r ? 'email' then
          select * into v_match from donors where lower(email) = lower(r->>'email') limit 1;
        end if;
        if v_match.id is null then
          select * into v_match from donors d
           where coalesce(d.postal_code,'') = coalesce(r->>'postal_code','')
             and ((v_type not in ('individual','household') and lower(d.organization_name) = lower(r->>'organization_name'))
               or (v_type in ('individual','household') and lower(coalesce(d.last_name,'')) = lower(coalesce(r->>'last_name',''))
                   and lower(coalesce(d.first_name,'')) = lower(coalesce(r->>'first_name',''))))
           limit 1;
        end if;
        if v_match.id is null then v_action := 'create';
        elsif v_mode = 'update' then v_action := 'update';
        else v_action := 'skip'; v_msg := 'Already exists';
        end if;
      end if;
    end if;

    if not v_dry and v_action in ('create','update') then
      begin
        if v_action = 'create' then
          v_saved := save_donor(r - 'donor_number' - 'id' || jsonb_build_object('donor_type', v_type));
        else
          -- existing values, overlaid with the fields the file provides
          v_saved := save_donor((to_jsonb(v_match) - 'display_name' - 'sort_name') || (r - 'donor_number' - 'id')
                                || jsonb_build_object('id', v_match.id, 'donor_type', v_type));
        end if;
        v_match.id := (v_saved->>'id')::uuid;
      exception when others then
        v_action := 'error'; v_msg := sqlerrm;
      end;
    end if;

    case v_action when 'create' then c_created := c_created + 1; when 'update' then c_updated := c_updated + 1;
                  when 'skip' then c_skipped := c_skipped + 1; else c_errors := c_errors + 1; end case;
    v_results := v_results || jsonb_build_object('row', i, 'action', v_action, 'donor_id', v_match.id,
                   'name', v_name, 'match_name', v_match.display_name, 'match_number', v_match.donor_number, 'message', v_msg);
  end loop;

  if not v_dry then
    perform _log('import', 'donors', null, jsonb_build_object('created', c_created, 'updated', c_updated, 'skipped', c_skipped, 'errors', c_errors));
  end if;
  return jsonb_build_object('created', c_created, 'updated', c_updated, 'skipped', c_skipped, 'errors', c_errors, 'results', v_results);
end $$;
