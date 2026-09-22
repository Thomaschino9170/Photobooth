-- =====================================================================
--  FlashBox CRM — Lot 5 : matériel, stock et dépenses
--  Prérequis : lots 1 à 4 déjà exécutés.
--  À coller dans Supabase > SQL Editor > New query, puis "Run".
--  Le script peut être relancé sans risque : il n'efface aucune donnée.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------

-- Inventaire : le matériel durable (borne, appareil, imprimante, fonds…)
create table if not exists public.materiel (
  id            uuid primary key default gen_random_uuid(),
  nom           text not null,
  categorie     text,
  numero_serie  text,
  date_achat    date,
  prix_achat    numeric(10,2),
  etat          text not null default 'ok' check (etat in ('ok', 'a_verifier', 'en_panne', 'hors_service')),
  notes         text,
  created_at    timestamptz not null default now(),
  created_by    text default public.email_courant(),
  updated_at    timestamptz not null default now(),
  updated_by    text default public.email_courant()
);

-- Consommables : papier, rubans, accessoires… Le stock n'est jamais saisi :
-- il est la somme des mouvements (entrées et sorties), donc toujours juste.
create table if not exists public.consommables (
  id                 uuid primary key default gen_random_uuid(),
  nom                text not null,
  unite              text not null default 'kit',
  tirages_par_unite  integer check (tirages_par_unite is null or tirages_par_unite > 0),
  prix_unitaire      numeric(10,2),
  seuil_alerte       numeric(10,2) not null default 1,
  decompte_auto      boolean not null default false,   -- retiré automatiquement à chaque prestation (papier de l'imprimante)
  actif              boolean not null default true,
  notes              text,
  created_at         timestamptz not null default now(),
  created_by         text default public.email_courant(),
  updated_at         timestamptz not null default now(),
  updated_by         text default public.email_courant()
);

-- Dépenses : qui a payé (un associé = frais avancé à rembourser, vide = compte de l'entreprise)
create table if not exists public.depenses (
  id             uuid primary key default gen_random_uuid(),
  date_depense   date not null default current_date,
  libelle        text not null,
  categorie      text,
  montant        numeric(10,2) not null check (montant > 0),
  paye_par       uuid references public.associes(id) on delete restrict,
  prestation_id  uuid references public.prestations(id) on delete set null,
  note           text,
  created_at     timestamptz not null default now(),
  created_by     text default public.email_courant(),
  updated_at     timestamptz not null default now(),
  updated_by     text default public.email_courant()
);
create index if not exists depenses_date_idx on public.depenses (date_depense);

-- Commandes : suivi commandée → reçue. À la réception, les consommables entrent
-- dans le stock (calcul) et le matériel durable est ajouté à l'inventaire.
create table if not exists public.commandes (
  id              uuid primary key default gen_random_uuid(),
  libelle         text not null,
  fournisseur     text,
  statut          text not null default 'commandee' check (statut in ('commandee', 'recue', 'annulee')),
  date_commande   date not null default current_date,
  date_prevue     date,
  date_reception  date,
  suivi           text,          -- numéro ou lien de suivi du colis
  lignes          jsonb not null default '[]'::jsonb,   -- [{type, consommable_id, libelle, quantite, prix_unitaire}]
  montant         numeric(10,2) not null default 0 check (montant >= 0),
  paye_par        uuid references public.associes(id) on delete restrict,   -- vide = compte de l'entreprise
  note            text,
  created_at      timestamptz not null default now(),
  created_by      text default public.email_courant(),
  updated_at      timestamptz not null default now(),
  updated_by      text default public.email_courant()
);
create index if not exists commandes_statut_idx on public.commandes (statut);

-- Mouvements de stock : + achat, − consommation, ± ajustement (inventaire)
create table if not exists public.mouvements_stock (
  id              uuid primary key default gen_random_uuid(),
  consommable_id  uuid not null references public.consommables(id) on delete cascade,
  date_mouvement  date not null default current_date,
  quantite        numeric(10,3) not null check (quantite <> 0),
  type            text not null check (type in ('achat', 'consommation', 'ajustement')),
  prestation_id   uuid references public.prestations(id) on delete cascade,
  depense_id      uuid references public.depenses(id) on delete cascade,
  note            text,
  created_at      timestamptz not null default now(),
  created_by      text default public.email_courant(),
  updated_at      timestamptz not null default now(),
  updated_by      text default public.email_courant()
);
create index if not exists mouvements_consommable_idx on public.mouvements_stock (consommable_id);

-- Colonnes ajoutées après coup (relance du script sans risque)
alter table public.consommables add column if not exists decompte_auto boolean not null default false;
alter table public.materiel add column if not exists commande_id uuid references public.commandes(id) on delete set null;

-- Nombre de tirages imprimés pendant une prestation (vide = estimation automatique)
alter table public.prestations add column if not exists nb_tirages integer check (nb_tirages is null or nb_tirages >= 0);


-- ---------------------------------------------------------------------
-- 2. Réglages et consommable de départ (seulement s'ils n'existent pas)
-- ---------------------------------------------------------------------
insert into public.parametres (cle, valeur) values
  ('materiel', '{"tirages_moyens": 150, "horizon_jours": 30}')
on conflict (cle) do nothing;

insert into public.consommables (nom, unite, tirages_par_unite, prix_unitaire, seuil_alerte, decompte_auto, notes)
select 'Kit HiTi P525L 10×15 (2 rouleaux + 2 rubans)', 'kit', 1000, 145, 1, true,
       'Prix indicatif : à ajuster selon le fournisseur.'
where not exists (select 1 from public.consommables);


-- ---------------------------------------------------------------------
-- 3. Horodatage automatique
-- ---------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['materiel', 'consommables', 'depenses', 'mouvements_stock', 'commandes'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_horodatage', t);
    execute format('create trigger %I before update on public.%I for each row execute function public.maj_horodatage()', t || '_horodatage', t);
  end loop;
end;
$$;


-- ---------------------------------------------------------------------
-- 4. Journal : version finale (identique dans tous les scripts)
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

drop trigger if exists materiel_journal on public.materiel;
create trigger materiel_journal after insert or update or delete on public.materiel
  for each row execute function public.journaliser('Matériel');
drop trigger if exists consommables_journal on public.consommables;
create trigger consommables_journal after insert or update or delete on public.consommables
  for each row execute function public.journaliser('Consommables');
drop trigger if exists depenses_journal on public.depenses;
create trigger depenses_journal after insert or update or delete on public.depenses
  for each row execute function public.journaliser('Dépenses');
drop trigger if exists commandes_journal on public.commandes;
create trigger commandes_journal after insert or update or delete on public.commandes
  for each row execute function public.journaliser('Commandes');
drop trigger if exists mouvements_stock_journal on public.mouvements_stock;
create trigger mouvements_stock_journal after insert or update or delete on public.mouvements_stock
  for each row execute function public.journaliser('Stock');


-- ---------------------------------------------------------------------
-- 5. Sécurité et temps réel
-- ---------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['materiel', 'consommables', 'depenses', 'mouvements_stock', 'commandes'] loop
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

-- Fin du script lot 5
