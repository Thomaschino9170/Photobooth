-- =====================================================================
--  FlashBox CRM — Lot 3 : prestations et planning
--  Prérequis : lot1_socle.sql puis lot2_devis.sql déjà exécutés.
--  À coller dans Supabase > SQL Editor > New query, puis "Run".
--  Le script peut être relancé sans risque : il n'efface aucune donnée.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------

-- Les prestations : une par événement. Créée automatiquement quand un
-- devis est accepté, ou à la main (prestation offerte, partenaire, test).
create table if not exists public.prestations (
  id                  uuid primary key default gen_random_uuid(),
  devis_id            uuid unique references public.devis(id) on delete set null,
  client_id           uuid references public.clients(id) on delete restrict,
  statut              text not null default 'a_venir'
                      check (statut in ('a_venir', 'realisee', 'annulee')),
  titre               text,
  evenement_type      text,
  date_evenement      date,
  heure_debut         time,
  heure_fin           time,
  lieu_nom            text,
  lieu_adresse        text,
  lieu_cp             text,
  lieu_ville          text,
  nb_invites          integer,
  contact_nom         text,          -- contact le jour J (témoin, wedding planner…)
  contact_tel         text,
  livraison_date      date,
  livraison_heure     time,
  recuperation_date   date,
  recuperation_heure  time,
  -- Un associé par rôle
  role_livraison      uuid references public.associes(id) on delete set null,
  role_presence       uuid references public.associes(id) on delete set null,
  role_recuperation   uuid references public.associes(id) on delete set null,
  role_prospection    uuid references public.associes(id) on delete set null,
  montant             numeric(10,2) not null default 0,
  notes               text,
  created_at          timestamptz not null default now(),
  created_by          text default public.email_courant(),
  updated_at          timestamptz not null default now(),
  updated_by          text default public.email_courant(),
  constraint prestation_identifiee check (client_id is not null or nullif(trim(titre), '') is not null)
);
create index if not exists prestations_date_idx on public.prestations (date_evenement);
create index if not exists prestations_client_idx on public.prestations (client_id);

-- Les indisponibilités des associés : une période (du… au…)
-- ou un créneau qui revient chaque semaine (ex. chaque dimanche 9h-13h)
create table if not exists public.indisponibilites (
  id            uuid primary key default gen_random_uuid(),
  associe_id    uuid not null references public.associes(id) on delete cascade,
  recurrence    text not null default 'aucune' check (recurrence in ('aucune', 'hebdo')),
  date_debut    date,
  date_fin      date,
  jour_semaine  integer check (jour_semaine between 1 and 7),   -- 1 = lundi … 7 = dimanche
  heure_debut   time,          -- vide = toute la journée
  heure_fin     time,
  motif         text,
  created_at    timestamptz not null default now(),
  created_by    text default public.email_courant(),
  updated_at    timestamptz not null default now(),
  updated_by    text default public.email_courant(),
  constraint indispo_valide check (
    (recurrence = 'aucune' and date_debut is not null and date_fin is not null and date_fin >= date_debut)
    or (recurrence = 'hebdo' and jour_semaine is not null)
  )
);
create index if not exists indisponibilites_associe_idx on public.indisponibilites (associe_id);


-- ---------------------------------------------------------------------
-- 2. Réglages du planning (seulement s'ils n'existent pas)
-- ---------------------------------------------------------------------
insert into public.parametres (cle, valeur) values
  ('planning', '{"nb_bornes": 1, "delai_installation_h": 2, "alerte_roles_jours": 7}')
on conflict (cle) do nothing;


-- ---------------------------------------------------------------------
-- 3. Horodatage automatique
-- ---------------------------------------------------------------------
drop trigger if exists prestations_horodatage on public.prestations;
create trigger prestations_horodatage
  before update on public.prestations
  for each row execute function public.maj_horodatage();

drop trigger if exists indisponibilites_horodatage on public.indisponibilites;
create trigger indisponibilites_horodatage
  before update on public.indisponibilites
  for each row execute function public.maj_horodatage();


-- ---------------------------------------------------------------------
-- 4. Journal : version finale (clients, devis, prestations, indisponibilités)
--    Même fonction dans les scripts des lots 1, 2 et 3 : l'ordre de
--    relance des scripts n'a donc pas d'importance.
-- ---------------------------------------------------------------------
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

drop trigger if exists prestations_journal on public.prestations;
create trigger prestations_journal
  after insert or update or delete on public.prestations
  for each row execute function public.journaliser('Prestations');

drop trigger if exists indisponibilites_journal on public.indisponibilites;
create trigger indisponibilites_journal
  after insert or update or delete on public.indisponibilites
  for each row execute function public.journaliser('Indisponibilités');


-- ---------------------------------------------------------------------
-- 5. Sécurité
-- ---------------------------------------------------------------------
alter table public.prestations      enable row level security;
alter table public.indisponibilites enable row level security;

drop policy if exists lecture_connectes on public.prestations;
create policy lecture_connectes on public.prestations
  for select to authenticated using (true);

drop policy if exists creation_connectes on public.prestations;
create policy creation_connectes on public.prestations
  for insert to authenticated with check (true);

drop policy if exists modification_connectes on public.prestations;
create policy modification_connectes on public.prestations
  for update to authenticated using (true) with check (true);

-- Seules les prestations créées à la main (sans devis) peuvent être supprimées.
-- Une prestation issue d'un devis accepté s'annule, elle ne disparaît pas.
drop policy if exists suppression_sans_devis on public.prestations;
create policy suppression_sans_devis on public.prestations
  for delete to authenticated using (devis_id is null);

drop policy if exists acces_complet_connectes on public.indisponibilites;
create policy acces_complet_connectes on public.indisponibilites
  for all to authenticated using (true) with check (true);


-- ---------------------------------------------------------------------
-- 6. Temps réel
-- ---------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['prestations', 'indisponibilites'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when others then
      null;
    end;
  end loop;
end;
$$;

-- Fin du script lot 3
