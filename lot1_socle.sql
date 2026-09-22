-- =====================================================================
--  FlashBox CRM — Lot 1 : socle (associés, paramètres, clients, journal)
--  À coller dans Supabase > SQL Editor > New query, puis cliquer "Run".
--  Le script peut être relancé sans risque : il n'efface aucune donnée.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Qui est connecté ? (lit le mail dans le jeton de connexion)
-- ---------------------------------------------------------------------
create or replace function public.email_courant()
returns text
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email',
    'système'
  );
$$;


-- ---------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------

-- Les associés (Thomas, Lisa, Erwan). Le mail fait le lien avec le compte de connexion.
create table if not exists public.associes (
  id          uuid primary key default gen_random_uuid(),
  prenom      text not null,
  nom         text,
  initiales   text,
  couleur     text not null default '#2563EB',
  email       text unique,
  created_at  timestamptz not null default now()
);

-- Les paramètres de l'application (une ligne par réglage, valeur au format JSON).
create table if not exists public.parametres (
  cle         text primary key,
  valeur      jsonb not null,
  updated_at  timestamptz not null default now(),
  updated_by  text
);

-- Les clients.
create table if not exists public.clients (
  id               uuid primary key default gen_random_uuid(),
  numero           integer generated always as identity unique,
  type             text not null default 'particulier'
                   check (type in ('particulier', 'entreprise', 'association')),
  prenom           text,
  nom              text,
  societe          text,
  siren            text,
  adresse          text,
  code_postal      text,
  ville            text,
  telephone        text,
  email            text,
  source           text,
  contact_prefere  text,
  commentaires     text,
  created_at       timestamptz not null default now(),
  created_by       text default public.email_courant(),
  updated_at       timestamptz not null default now(),
  updated_by       text default public.email_courant(),
  -- Un client doit au minimum avoir un nom OU un nom de société
  constraint client_identifie check (
    coalesce(nullif(trim(nom), ''), nullif(trim(societe), '')) is not null
  )
);

-- Le journal d'événements (alimenté automatiquement, non modifiable).
create table if not exists public.journal (
  id           bigint generated always as identity primary key,
  date_action  timestamptz not null default now(),
  auteur       text not null default public.email_courant(),
  module       text not null,
  action       text not null,
  cible        text,
  champs       text[],
  ref_id       text,
  details      text
);
alter table public.journal add column if not exists details text;
create index if not exists journal_date_idx on public.journal (date_action desc);


-- ---------------------------------------------------------------------
-- 3. Données de départ (seulement si elles n'existent pas déjà)
-- ---------------------------------------------------------------------
insert into public.parametres (cle, valeur) values
  ('entreprise',        '{"nom": "FlashBox"}'),
  ('sources',           '["Instagram", "Facebook", "Bouche-à-oreille", "Recommandation", "Site web", "Google", "Salon / événement", "Autre"]'),
  ('contacts_preferes', '["Appel", "SMS", "WhatsApp", "Mail"]'),
  ('alertes_clients',   '{"contact": "rouge", "adresse": "rouge", "societe": "rouge", "nom": "orange", "email": "orange", "telephone": "aucune", "siren": "orange", "source": "orange", "contact_prefere": "aucune", "formats": "orange", "doublons": "orange"}')
on conflict (cle) do nothing;

insert into public.associes (prenom, initiales, couleur)
select v.prenom, v.initiales, v.couleur
from (values
  ('Thomas', null, '#2563EB'),
  ('Lisa',   null, '#DB2777'),
  ('Erwan',  null, '#16A34A')
) as v(prenom, initiales, couleur)
where not exists (select 1 from public.associes);


-- ---------------------------------------------------------------------
-- 4. Automatismes
-- ---------------------------------------------------------------------

-- 4a. Date et auteur de la dernière modification
create or replace function public.maj_horodatage()
returns trigger
language plpgsql
as $$
begin
  new.updated_at := now();
  new.updated_by := public.email_courant();
  return new;
end;
$$;

drop trigger if exists clients_horodatage on public.clients;
create trigger clients_horodatage
  before update on public.clients
  for each row execute function public.maj_horodatage();

drop trigger if exists parametres_horodatage on public.parametres;
create trigger parametres_horodatage
  before insert or update on public.parametres
  for each row execute function public.maj_horodatage();

-- 4b. Journal automatique : chaque création / modification / suppression est tracée
create or replace function public.journaliser()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old      jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new      jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_ligne    jsonb := coalesce(v_new, v_old);
  v_cible    text;
  v_champs   text[];
  v_action   text;
  v_details  text;
  v_nom      text;
  v_jours    text[] := array['lundi', 'mardi', 'mercredi', 'jeudi', 'vendredi', 'samedi', 'dimanche'];
  v_montant  text;
begin
  v_action := case tg_op when 'INSERT' then 'création'
                         when 'UPDATE' then 'modification'
                         else 'suppression' end;

  if tg_op = 'UPDATE' then
    select array_agg(n.key order by n.key) into v_champs
    from jsonb_each(v_new) as n
    where n.key not in ('updated_at', 'updated_by', 'created_at', 'created_by')
      and n.value is distinct from (v_old -> n.key);

    if v_champs is null then
      return new;  -- rien n'a changé, rien à journaliser
    end if;

    -- Changement de statut : on le trace comme tel
    if 'statut' = any(v_champs) then
      v_action  := 'statut';
      v_details := v_new ->> 'statut';
    end if;
  end if;

  v_montant := replace(to_char(nullif(v_ligne ->> 'montant', '')::numeric, 'FM9999999990.00'), '.', ',') || ' €';

  if tg_table_name in ('devis', 'prestations', 'factures') then
    select coalesce(nullif(trim(coalesce(c.societe, '')), ''),
                    nullif(trim(concat_ws(' ', c.prenom, c.nom)), ''))
      into v_nom
    from public.clients c
    where c.id = nullif(v_ligne ->> 'client_id', '')::uuid;

    if tg_table_name = 'devis' then
      v_cible := concat_ws(' – ', v_ligne ->> 'reference', v_nom);
    elsif tg_table_name = 'factures' then
      v_cible := concat_ws(' – ', coalesce(v_ligne ->> 'reference', 'Brouillon'), v_nom);
    else
      v_cible := concat_ws(' – ',
        to_char(nullif(v_ligne ->> 'date_evenement', '')::date, 'DD/MM/YYYY'),
        coalesce(v_nom, nullif(trim(coalesce(v_ligne ->> 'titre', '')), '')));
    end if;

  elsif tg_table_name = 'indisponibilites' then
    select a.prenom into v_nom from public.associes a
    where a.id = nullif(v_ligne ->> 'associe_id', '')::uuid;
    v_cible := concat_ws(' – ', v_nom,
      case when v_ligne ->> 'recurrence' = 'hebdo'
           then 'chaque ' || v_jours[(v_ligne ->> 'jour_semaine')::integer]
           else to_char((v_ligne ->> 'date_debut')::date, 'DD/MM/YYYY')
                || case when v_ligne ->> 'date_fin' is distinct from v_ligne ->> 'date_debut'
                        then ' au ' || to_char((v_ligne ->> 'date_fin')::date, 'DD/MM/YYYY') else '' end
      end);

  elsif tg_table_name = 'paiements' then
    select f.reference into v_nom from public.factures f
    where f.id = nullif(v_ligne ->> 'facture_id', '')::uuid;
    v_cible := concat_ws(' – ', v_montant, v_nom);

  elsif tg_table_name in ('depenses', 'commandes', 'fonds_mouvements') then
    v_cible := concat_ws(' – ', v_ligne ->> 'libelle', v_montant);

  elsif tg_table_name = 'mouvements_stock' then
    select c.nom into v_nom from public.consommables c
    where c.id = nullif(v_ligne ->> 'consommable_id', '')::uuid;
    v_cible := concat_ws(' – ', v_nom,
      case when (v_ligne ->> 'quantite')::numeric > 0 then '+' else '' end
        || replace(rtrim(rtrim(v_ligne ->> 'quantite', '0'), '.'), '.', ','));

  elsif tg_table_name = 'repartitions' then
    select coalesce(nullif(trim(coalesce(c.societe, '')), ''),
                    nullif(trim(concat_ws(' ', c.prenom, c.nom)), ''),
                    nullif(trim(coalesce(p.titre, '')), ''))
      into v_nom
    from public.prestations p
    left join public.clients c on c.id = p.client_id
    where p.id = nullif(v_ligne ->> 'prestation_id', '')::uuid;
    v_cible := concat_ws(' – ', v_nom,
      replace(to_char(nullif(v_ligne ->> 'base', '')::numeric, 'FM9999999990.00'), '.', ',') || ' €');

  else
    v_cible := coalesce(
      nullif(concat_ws(' – ',
        nullif(trim(coalesce(v_ligne ->> 'societe', '')), ''),
        nullif(trim(concat_ws(' ', v_ligne ->> 'prenom', v_ligne ->> 'nom')), '')
      ), ''),
      v_ligne ->> 'nom',
      v_ligne ->> 'cle',
      v_ligne ->> 'id'
    );
  end if;

  insert into public.journal (module, action, cible, champs, ref_id, details)
  values (tg_argv[0], v_action, v_cible, v_champs,
          coalesce(v_ligne ->> 'id', v_ligne ->> 'cle'), v_details);

  return coalesce(new, old);
end;
$$;

drop trigger if exists clients_journal on public.clients;
create trigger clients_journal
  after insert or update or delete on public.clients
  for each row execute function public.journaliser('Clients');

drop trigger if exists parametres_journal on public.parametres;
create trigger parametres_journal
  after insert or update or delete on public.parametres
  for each row execute function public.journaliser('Paramètres');

drop trigger if exists associes_journal on public.associes;
create trigger associes_journal
  after insert or update or delete on public.associes
  for each row execute function public.journaliser('Associés');


-- ---------------------------------------------------------------------
-- 5. Sécurité : seules les personnes connectées ont accès, toutes avec les mêmes droits
-- ---------------------------------------------------------------------
alter table public.associes   enable row level security;
alter table public.parametres enable row level security;
alter table public.clients    enable row level security;
alter table public.journal    enable row level security;

drop policy if exists acces_complet_connectes on public.associes;
create policy acces_complet_connectes on public.associes
  for all to authenticated using (true) with check (true);

drop policy if exists acces_complet_connectes on public.parametres;
create policy acces_complet_connectes on public.parametres
  for all to authenticated using (true) with check (true);

drop policy if exists acces_complet_connectes on public.clients;
create policy acces_complet_connectes on public.clients
  for all to authenticated using (true) with check (true);

-- Journal : lecture seule pour tout le monde, personne ne peut le modifier
drop policy if exists lecture_connectes on public.journal;
create policy lecture_connectes on public.journal
  for select to authenticated using (true);

revoke insert, update, delete on public.journal from anon, authenticated;


-- ---------------------------------------------------------------------
-- 6. Temps réel : les modifications d'un associé apparaissent chez les autres
-- ---------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['clients', 'journal', 'parametres', 'associes'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when others then
      null;  -- déjà ajoutée : on ignore
    end;
  end loop;
end;
$$;

-- Fin du script lot 1
