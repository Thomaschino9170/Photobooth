-- =====================================================================
--  FlashBox CRM — Lot 6 : répartition des bénéfices et fonds de commerce
--  Prérequis : lots 1 à 5 déjà exécutés.
--  À coller dans Supabase > SQL Editor > New query, puis "Run".
--  Le script peut être relancé sans risque : il n'efface aucune donnée.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------

-- Une répartition par prestation réalisée. Les lignes sont figées à la
-- validation : si les réglages changent plus tard, l'historique ne bouge pas.
create table if not exists public.repartitions (
  id              uuid primary key default gen_random_uuid(),
  prestation_id   uuid not null unique references public.prestations(id) on delete cascade,
  date_repartition date not null default current_date,
  statut          text not null default 'validee' check (statut in ('validee', 'reglee')),
  base            numeric(10,2) not null default 0,      -- montant de la prestation
  taux_fonds      numeric(5,2) not null default 30,
  montant_fonds   numeric(10,2) not null default 0,      -- part du fonds + frais qu'il a avancés
  total_frais     numeric(10,2) not null default 0,
  total_primes    numeric(10,2) not null default 0,
  reste           numeric(10,2) not null default 0,      -- partagé en parts égales
  lignes          jsonb not null default '[]'::jsonb,    -- [{type, associe_id, libelle, montant}]
  date_reglement  date,
  note            text,
  created_at      timestamptz not null default now(),
  created_by      text default public.email_courant(),
  updated_at      timestamptz not null default now(),
  updated_by      text default public.email_courant()
);

-- Mouvements saisis à la main sur le fonds de commerce :
-- apport, retrait, remboursement d'un frais avancé, correction.
create table if not exists public.fonds_mouvements (
  id              uuid primary key default gen_random_uuid(),
  date_mouvement  date not null default current_date,
  libelle         text not null,
  montant         numeric(10,2) not null check (montant <> 0),   -- positif = entrée, négatif = sortie
  type            text not null default 'ajustement' check (type in ('apport', 'retrait', 'remboursement', 'ajustement')),
  associe_id      uuid references public.associes(id) on delete set null,
  note            text,
  created_at      timestamptz not null default now(),
  created_by      text default public.email_courant(),
  updated_at      timestamptz not null default now(),
  updated_by      text default public.email_courant()
);
create index if not exists fonds_mouvements_date_idx on public.fonds_mouvements (date_mouvement);

-- Frais avancés par un associé : une fois remboursés, on les marque
alter table public.depenses  add column if not exists rembourse boolean not null default false;
alter table public.commandes add column if not exists rembourse boolean not null default false;


-- ---------------------------------------------------------------------
-- 2. Réglages de la répartition (seulement s'ils n'existent pas)
-- ---------------------------------------------------------------------
insert into public.parametres (cle, valeur) values
  ('repartition', '{"taux_fonds": 30, "primes": {"prospection": 25, "livraison": 30, "recuperation": 20, "presence": 50}, "partage": "tous", "inclure_papier": true}')
on conflict (cle) do nothing;


-- ---------------------------------------------------------------------
-- 3. Horodatage automatique
-- ---------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['repartitions', 'fonds_mouvements'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_horodatage', t);
    execute format('create trigger %I before update on public.%I for each row execute function public.maj_horodatage()', t || '_horodatage', t);
  end loop;
end;
$$;


-- ---------------------------------------------------------------------
-- 4. Journal : version finale (identique dans les scripts des 6 lots)
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

drop trigger if exists repartitions_journal on public.repartitions;
create trigger repartitions_journal after insert or update or delete on public.repartitions
  for each row execute function public.journaliser('Répartition');

drop trigger if exists fonds_mouvements_journal on public.fonds_mouvements;
create trigger fonds_mouvements_journal after insert or update or delete on public.fonds_mouvements
  for each row execute function public.journaliser('Fonds');


-- ---------------------------------------------------------------------
-- 5. Sécurité et temps réel
-- ---------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['repartitions', 'fonds_mouvements'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists acces_complet_connectes on public.%I', t);
    execute format('create policy acces_complet_connectes on public.%I for all to authenticated using (true) with check (true)', t);
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when others then
      null;
    end;
  end loop;
end;
$$;

-- Fin du script lot 6
