-- Optional metadata-only bootstrap for creating and joining private device
-- groups before a desktop/storage device is available. This schema must not
-- store originals, thumbnails, vault keys, LAN bearer tokens, or pairing
-- tokens.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.device_groups (
  id uuid primary key default gen_random_uuid(),
  owner_user_id uuid not null default auth.uid(),
  name text not null check (length(trim(name)) between 1 and 120),
  created_at timestamptz not null default now()
);

create table if not exists public.device_group_devices (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.device_groups(id) on delete cascade,
  user_id uuid not null default auth.uid(),
  client_device_id text not null,
  display_name text not null check (length(trim(display_name)) between 1 and 120),
  platform text not null check (length(trim(platform)) between 1 and 40),
  role text not null check (role in ('owner', 'member')),
  capability text not null check (capability in ('metadata_only', 'desktop', 'storage')),
  public_key text,
  endpoint_hints jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  revoked_at timestamptz,
  unique(group_id, user_id),
  unique(group_id, client_device_id)
);

create table if not exists public.device_group_invites (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.device_groups(id) on delete cascade,
  secret_hash text not null,
  role text not null default 'member' check (role in ('member')),
  capability text not null default 'metadata_only' check (capability in ('metadata_only')),
  created_by_user_id uuid not null default auth.uid(),
  accepted_by_user_id uuid,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  accepted_at timestamptz
);

alter table public.device_group_devices
  add column if not exists client_device_id text,
  add column if not exists public_key text,
  add column if not exists endpoint_hints jsonb not null default '{}'::jsonb;

update public.device_group_devices
   set client_device_id = coalesce(nullif(client_device_id, ''), user_id::text)
 where client_device_id is null or client_device_id = '';

alter table public.device_group_devices
  alter column client_device_id set not null;

create unique index if not exists device_group_devices_group_client_device_id_key
  on public.device_group_devices(group_id, client_device_id);

alter table public.device_groups enable row level security;
alter table public.device_group_devices enable row level security;
alter table public.device_group_invites enable row level security;

revoke all on public.device_groups from anon, authenticated;
revoke all on public.device_group_devices from anon, authenticated;
revoke all on public.device_group_invites from anon, authenticated;

grant usage on schema public to authenticated;
grant select, insert on public.device_groups to authenticated;
grant select, insert, update on public.device_group_devices to authenticated;
grant insert (group_id, secret_hash, role, capability, expires_at)
  on public.device_group_invites to authenticated;
grant select (
  id,
  group_id,
  role,
  capability,
  created_by_user_id,
  accepted_by_user_id,
  created_at,
  expires_at,
  accepted_at
) on public.device_group_invites to authenticated;

create or replace function public.is_device_group_owner(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.device_groups g
    where g.id = p_group_id
      and g.owner_user_id = auth.uid()
  )
$$;

create or replace function public.is_device_group_member(p_group_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.device_group_devices d
    where d.group_id = p_group_id
      and d.user_id = auth.uid()
      and d.revoked_at is null
  )
$$;

revoke all on function public.is_device_group_owner(uuid) from public;
revoke all on function public.is_device_group_member(uuid) from public;
grant execute on function public.is_device_group_owner(uuid) to authenticated;
grant execute on function public.is_device_group_member(uuid) to authenticated;

drop policy if exists "device groups are visible to members" on public.device_groups;
create policy "device groups are visible to members"
on public.device_groups
for select
to authenticated
using (
  owner_user_id = auth.uid()
  or public.is_device_group_member(id)
);

drop policy if exists "users can create owned device groups" on public.device_groups;
create policy "users can create owned device groups"
on public.device_groups
for insert
to authenticated
with check (owner_user_id = auth.uid());

drop policy if exists "device memberships are visible to group members" on public.device_group_devices;
create policy "device memberships are visible to group members"
on public.device_group_devices
for select
to authenticated
using (
  user_id = auth.uid()
  or public.is_device_group_member(group_id)
);

drop policy if exists "users can register their owner bootstrap device" on public.device_group_devices;
drop policy if exists "users can register their own bootstrap device" on public.device_group_devices;
create policy "users can register their owner bootstrap device"
on public.device_group_devices
for insert
to authenticated
with check (
  user_id = auth.uid()
  and role = 'owner'
  and public.is_device_group_owner(group_id)
);

drop policy if exists "group members can create invites" on public.device_group_invites;
create policy "group members can create invites"
on public.device_group_invites
for insert
to authenticated
with check (
  created_by_user_id = auth.uid()
  and public.is_device_group_member(group_id)
);

drop policy if exists "group members can view their invites" on public.device_group_invites;
create policy "group members can view their invites"
on public.device_group_invites
for select
to authenticated
using (
  public.is_device_group_member(group_id)
);

drop function if exists public.claim_device_group_invite(uuid, text, text, text);

create or replace function public.claim_device_group_invite(
  p_invite_id uuid,
  p_invite_secret text,
  p_client_device_id text,
  p_display_name text,
  p_platform text
)
returns table(group_id uuid, group_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_user_id uuid := auth.uid();
  v_invite record;
  v_client_device_id text := coalesce(nullif(trim(p_client_device_id), ''), auth.uid()::text);
begin
  if v_user_id is null then
    raise exception 'authenticated session required';
  end if;

  select i.id, i.group_id, g.name
    into v_invite
    from public.device_group_invites i
    join public.device_groups g on g.id = i.group_id
   where i.id = p_invite_id
     and i.secret_hash = encode(digest(p_invite_secret, 'sha256'), 'hex')
     and i.accepted_at is null
     and i.expires_at > now()
   for update of i;

  if not found then
    raise exception 'invite was not found, expired, or already used';
  end if;

  if exists (
    select 1
      from public.device_group_devices d
     where d.group_id = v_invite.group_id
       and (d.user_id = v_user_id or d.client_device_id = v_client_device_id)
       and d.revoked_at is not null
  ) then
    raise exception 'device membership has been revoked';
  end if;

  insert into public.device_group_devices (
    group_id,
    user_id,
    client_device_id,
    display_name,
    platform,
    role,
    capability
  )
  values (
    v_invite.group_id,
    v_user_id,
    v_client_device_id,
    coalesce(nullif(trim(p_display_name), ''), 'This device'),
    coalesce(nullif(trim(p_platform), ''), 'android'),
    'member',
    'metadata_only'
  )
  on conflict on constraint device_group_devices_group_id_user_id_key do update
    set display_name = excluded.display_name,
        client_device_id = excluded.client_device_id,
        platform = excluded.platform;

  update public.device_group_invites
     set accepted_at = now(),
         accepted_by_user_id = v_user_id
   where id = v_invite.id;

  return query select v_invite.group_id::uuid, v_invite.name::text;
end;
$$;

revoke all on function public.claim_device_group_invite(uuid, text, text, text, text) from public;
grant execute on function public.claim_device_group_invite(uuid, text, text, text, text) to authenticated;
