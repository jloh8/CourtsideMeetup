-- CourtShare London — Supabase schema
-- Run this once in Supabase Studio → SQL Editor → New query → Run.
-- Safe to re-run on a fresh project; it will error if objects already exist
-- (drop the project's tables first if you need to re-apply from scratch).

create extension if not exists "pgcrypto";

-- ============================================================
-- TABLES
-- ============================================================

-- Static reference data — the badminton venues.
create table venues (
  id   uuid primary key default gen_random_uuid(),
  name text not null,
  area text not null
);

insert into venues (name, area) values
  ('Finsbury Leisure Centre',               'Clerkenwell'),
  ('Kensington Leisure Centre',             'North Kensington'),
  ('Crystal Palace National Sports Centre', 'Crystal Palace'),
  ('Copper Box Arena',                      'Olympic Park, Stratford'),
  ('Britannia Leisure Centre',              'Hoxton'),
  ('Swiss Cottage Leisure Centre',          'Swiss Cottage'),
  ('Walthamstow Leisure Centre',            'Walthamstow'),
  ('Leytonstone Leisure Centre',            'Leytonstone');

-- One row per signed-up person. id = auth.users.id (1:1 with the
-- phone-verified Supabase Auth account) — there is deliberately no
-- separate "whatsapp number" field here. The number people message on
-- IS the number they verified via SMS OTP (auth.users.phone), so there's
-- nothing for anyone to fake or mistype.
create table profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  name       text not null check (char_length(name) between 2 and 40),
  created_at timestamptz not null default now()
);

-- A posted court slot.
create table slots (
  id            uuid primary key default gen_random_uuid(),
  venue_id      uuid not null references venues(id),
  date          date not null,
  time          time not null,
  capacity      int  not null check (capacity between 1 and 20),
  organizer_id  uuid not null references profiles(id),
  cancelled     boolean not null default false,
  created_at    timestamptz not null default now()
);
create index slots_venue_idx on slots(venue_id);

-- Who has joined a slot. The primary key alone makes double-joining
-- structurally impossible — no app-level dedup logic required.
create table slot_members (
  slot_id   uuid not null references slots(id) on delete cascade,
  member_id uuid not null references profiles(id),
  joined_at timestamptz not null default now(),
  primary key (slot_id, member_id)
);
create index slot_members_slot_idx on slot_members(slot_id);

-- Community moderation flags.
create table slot_reports (
  slot_id     uuid not null references slots(id) on delete cascade,
  reporter_id uuid not null references profiles(id),
  created_at  timestamptz not null default now(),
  primary key (slot_id, reporter_id)
);
create index slot_reports_slot_idx on slot_reports(slot_id);

-- ============================================================
-- TRIGGERS — the rules that actually can't be bypassed from the client
-- ============================================================

-- Atomic capacity check. `for update` locks the slots row for the rest
-- of this transaction, so if two people join at the exact same moment,
-- the second one's insert waits for the first to finish, re-reads the
-- count, and correctly sees the slot as full. This is the fix for the
-- race condition the client-only version had no way to prevent.
create or replace function enforce_slot_capacity()
returns trigger as $$
declare
  cap int;
  current_count int;
  is_cancelled boolean;
begin
  select capacity, cancelled into cap, is_cancelled
  from slots where id = new.slot_id
  for update;

  if is_cancelled then
    raise exception 'This slot has been cancelled';
  end if;

  select count(*) into current_count from slot_members where slot_id = new.slot_id;

  if current_count >= cap then
    raise exception 'This slot is already full';
  end if;

  return new;
end;
$$ language plpgsql security definer;

create trigger trg_enforce_capacity
before insert on slot_members
for each row execute function enforce_slot_capacity();

-- Rate limit (max 3 open slots per organizer) + duplicate-post guard.
-- Both checked server-side against the real, authenticated organizer_id
-- — not a display name that could vary between sessions.
create or replace function enforce_slot_posting_rules()
returns trigger as $$
declare
  open_count int;
  dupe_count int;
begin
  select count(*) into open_count
  from slots s
  where s.organizer_id = new.organizer_id
    and s.cancelled = false
    and (select count(*) from slot_members m where m.slot_id = s.id) < s.capacity;

  if open_count >= 3 then
    raise exception 'You already have 3 open slots — fill or cancel one first';
  end if;

  select count(*) into dupe_count
  from slots s
  where s.organizer_id = new.organizer_id
    and s.venue_id = new.venue_id
    and s.date = new.date
    and s.time = new.time
    and s.cancelled = false;

  if dupe_count > 0 then
    raise exception 'You already posted a slot for this time';
  end if;

  return new;
end;
$$ language plpgsql security definer;

create trigger trg_enforce_posting_rules
before insert on slots
for each row execute function enforce_slot_posting_rules();

-- The organizer is automatically the first member of their own slot.
create or replace function add_organizer_as_member()
returns trigger as $$
begin
  insert into slot_members (slot_id, member_id) values (new.id, new.organizer_id);
  return new;
end;
$$ language plpgsql security definer;

create trigger trg_add_organizer
after insert on slots
for each row execute function add_organizer_as_member();

-- ============================================================
-- ROW LEVEL SECURITY
-- ============================================================

alter table venues       enable row level security;
alter table profiles     enable row level security;
alter table slots        enable row level security;
alter table slot_members enable row level security;
alter table slot_reports enable row level security;

create policy "venues readable by authenticated users"
  on venues for select to authenticated using (true);

-- Profiles are private by default — nobody can read another person's
-- row directly. Names get to other people ONLY through the
-- get_venue_board() function below, and WhatsApp numbers ONLY through
-- that same function's guarded case-when. There is no direct path from
-- the client to another user's phone number.
create policy "users manage their own profile"
  on profiles for all to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy "slots readable by authenticated users"
  on slots for select to authenticated using (true);

create policy "users can post their own slots"
  on slots for insert to authenticated with check (organizer_id = auth.uid());

create policy "organizer can update their own slot"
  on slots for update to authenticated
  using (organizer_id = auth.uid()) with check (organizer_id = auth.uid());

-- slot_members rows carry no PII beyond an opaque user id, so broad read
-- access is fine — it's what lets everyone see live spot counts.
create policy "slot members readable by authenticated users"
  on slot_members for select to authenticated using (true);

create policy "users can join a slot as themselves"
  on slot_members for insert to authenticated with check (member_id = auth.uid());

create policy "users can leave a slot themselves"
  on slot_members for delete to authenticated using (member_id = auth.uid());

create policy "reports readable by authenticated users"
  on slot_reports for select to authenticated using (true);

create policy "users can report as themselves"
  on slot_reports for insert to authenticated with check (reporter_id = auth.uid());

-- ============================================================
-- THE ONE READ FUNCTION THE APP ACTUALLY USES
-- ============================================================

-- Returns everything the venue board needs in a single call: every open
-- slot at a venue, who's organizing it, who's joined (names only), and
-- — ONLY when the slot is full AND the caller is one of its members —
-- everyone's verified WhatsApp number. Runs as security definer so it
-- can read auth.users.phone (which `authenticated` cannot do directly)
-- and profiles across users (which RLS otherwise blocks), while keeping
-- the actual privacy decision (full + member) baked into the query
-- itself rather than trusted to the UI.
create or replace function get_venue_board(p_venue_id uuid)
returns table (
  id             uuid,
  date           date,
  "time"         time,
  capacity       int,
  organizer_id   uuid,
  organizer_name text,
  member_count   bigint,
  member_names   text[],
  is_member      boolean,
  is_organizer   boolean,
  is_full        boolean,
  whatsapps      text[]
) as $$
  with base as (
    select
      s.id, s.date, s.time, s.capacity, s.organizer_id, s.created_at,
      op.name as organizer_name,
      count(sm.member_id) as member_count,
      array_agg(mp.name order by sm.joined_at) as member_names,
      bool_or(sm.member_id = auth.uid()) as is_member,
      (s.organizer_id = auth.uid()) as is_organizer
    from slots s
    join profiles op on op.id = s.organizer_id
    left join slot_members sm on sm.slot_id = s.id
    left join profiles mp on mp.id = sm.member_id
    where s.venue_id = p_venue_id
      and s.cancelled = false
      and (select count(*) from slot_reports r where r.slot_id = s.id) < 3
    group by s.id, op.name
  )
  select
    b.id, b.date, b.time, b.capacity, b.organizer_id, b.organizer_name,
    b.member_count, b.member_names, b.is_member, b.is_organizer,
    (b.member_count >= b.capacity) as is_full,
    case when b.member_count >= b.capacity and b.is_member
      then (
        select array_agg(u.phone order by sm2.joined_at)
        from slot_members sm2
        join auth.users u on u.id = sm2.member_id
        where sm2.slot_id = b.id
      )
      else null
    end as whatsapps
  from base b
  order by b.created_at asc;
$$ language sql security definer stable;

grant execute on function get_venue_board(uuid) to authenticated;

-- ============================================================
-- REALTIME — so joins/posts push to other open tabs instead of polling
-- ============================================================
alter publication supabase_realtime add table slots;
alter publication supabase_realtime add table slot_members;
alter publication supabase_realtime add table slot_reports;
