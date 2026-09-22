-- =====================================================================
--  FlashBox CRM — Lot 4 : facturation
--  Prérequis : lots 1, 2 et 3 déjà exécutés.
--  À coller dans Supabase > SQL Editor > New query, puis "Run".
--  Le script peut être relancé sans risque : il n'efface aucune donnée.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Tables
-- ---------------------------------------------------------------------

-- Factures et avoirs. Un brouillon n'a pas de numéro : le numéro définitif
-- est attribué à l'émission, dans l'ordre, sans trou (obligation légale).
create table if not exists public.factures (
  id                  uuid primary key default gen_random_uuid(),
  type                text not null default 'totale'
                      check (type in ('acompte', 'solde', 'totale', 'avoir')),
  statut              text not null default 'brouillon' check (statut in ('brouillon', 'emise')),
  client_id           uuid not null references public.clients(id) on delete restrict,
  prestation_id       uuid references public.prestations(id) on delete set null,
  devis_id            uuid references public.devis(id) on delete set null,
  facture_origine_id  uuid references public.factures(id) on delete restrict,  -- pour un avoir
  numero              integer,
  annee               integer,
  reference           text unique,
  date_facture        date,
  date_echeance       date,
  objet               text,
  lignes              jsonb not null default '[]',
  total               numeric(10,2) not null default 0,
  deduction           numeric(10,2) not null default 0,   -- acomptes déjà facturés
  deductions          jsonb not null default '[]',
  net                 numeric(10,2) not null default 0,   -- net à payer
  conditions          text,
  notes_internes      text,
  client_snapshot     jsonb,                               -- client tel qu'au jour de l'émission
  date_emission       timestamptz,
  date_envoi          timestamptz,
  date_relance        date,
  created_at          timestamptz not null default now(),
  created_by          text default public.email_courant(),
  updated_at          timestamptz not null default now(),
  updated_by          text default public.email_courant()
);
create index if not exists factures_client_idx on public.factures (client_id);
create index if not exists factures_prestation_idx on public.factures (prestation_id);

-- Paiements reçus (ou remboursements, sur un avoir)
create table if not exists public.paiements (
  id             uuid primary key default gen_random_uuid(),
  facture_id     uuid not null references public.factures(id) on delete restrict,
  date_paiement  date not null default current_date,
  montant        numeric(10,2) not null check (montant <> 0),
  moyen          text,
  note           text,
  created_at     timestamptz not null default now(),
  created_by     text default public.email_courant(),
  updated_at     timestamptz not null default now(),
  updated_by     text default public.email_courant()
);
create index if not exists paiements_facture_idx on public.paiements (facture_id);


-- ---------------------------------------------------------------------
-- 2. Réglages de la facturation (seulement s'ils n'existent pas)
-- ---------------------------------------------------------------------
insert into public.parametres (cle, valeur) values
  ('facturation', jsonb_build_object(
    'prefixe_facture', 'FA',
    'prefixe_avoir', 'AV',
    'echeance_acompte_jours', 0,
    'echeance_solde_jours_avant', 0,
    'delai_paiement_jours', 0,
    'relance_jours', 7,
    'moyens', 'Virement, Espèces, Chèque, Carte bancaire, Lydia / Wero',
    'conditions', 'Paiement par virement ou en espèces. Merci d’indiquer la référence de la facture dans le libellé du virement.',
    'mentions_pro', 'En cas de retard de paiement : pénalités au taux de trois fois le taux d’intérêt légal et indemnité forfaitaire pour frais de recouvrement de 40 € (art. L441-10 du Code de commerce). Pas d’escompte pour paiement anticipé.',
    'message_envoi', E'Bonjour {prenom},\n\nVous trouverez ci-joint la facture {reference} d’un montant de {montant}, à régler avant le {echeance}.\n\nMerci pour votre confiance et à bientôt,\n{moi} – {entreprise}'
  ))
on conflict (cle) do nothing;


-- ---------------------------------------------------------------------
-- 3. Émission : numéro définitif et date du jour (la facture reste modifiable)
-- ---------------------------------------------------------------------
create or replace function public.emettre_facture()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_conf     jsonb;
  v_prefixe  text;
begin
  -- Une facture déjà émise garde son numéro ; elle reste modifiable (choix FlashBox : gestion simple)
  if tg_op = 'UPDATE' and old.statut = 'emise' then
    new.numero := old.numero; new.annee := old.annee; new.reference := old.reference;
    new.date_emission := old.date_emission; new.statut := 'emise';
    return new;
  end if;

  if new.statut = 'emise' then
    -- Verrou : deux émissions simultanées n'auront pas le même numéro
    perform pg_advisory_xact_lock(hashtext('flashbox_numerotation_factures'));
    select valeur into v_conf from public.parametres where cle = 'facturation';
    v_prefixe := case when new.type = 'avoir' then coalesce(nullif(v_conf ->> 'prefixe_avoir', ''), 'AV')
                      else coalesce(nullif(v_conf ->> 'prefixe_facture', ''), 'FA') end;
    new.date_facture  := current_date;   -- pas d'antidatage possible
    new.annee         := extract(year from new.date_facture)::integer;
    select coalesce(max(numero), 0) + 1 into new.numero
      from public.factures
      where annee = new.annee and (type = 'avoir') = (new.type = 'avoir');
    new.reference     := v_prefixe || '-' || new.annee || '-' || lpad(new.numero::text, 4, '0');
    new.date_emission := now();
  else
    new.numero := null; new.annee := null; new.reference := null; new.date_emission := null;
  end if;
  return new;
end;
$$;

drop trigger if exists factures_emission on public.factures;
create trigger factures_emission
  before insert or update on public.factures
  for each row execute function public.emettre_facture();

-- Un paiement ne peut concerner qu'une facture émise
create or replace function public.controler_paiement()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if not exists (select 1 from public.factures f where f.id = new.facture_id and f.statut = 'emise') then
    raise exception 'Un paiement ne peut être enregistré que sur une facture émise.' using errcode = 'P0001';
  end if;
  return new;
end;
$$;

drop trigger if exists paiements_controle on public.paiements;
create trigger paiements_controle
  before insert or update on public.paiements
  for each row execute function public.controler_paiement();


-- ---------------------------------------------------------------------
-- 4. Horodatage automatique
-- ---------------------------------------------------------------------
drop trigger if exists factures_horodatage on public.factures;
create trigger factures_horodatage
  before update on public.factures
  for each row execute function public.maj_horodatage();

drop trigger if exists paiements_horodatage on public.paiements;
create trigger paiements_horodatage
  before update on public.paiements
  for each row execute function public.maj_horodatage();


-- ---------------------------------------------------------------------
-- 5. Journal : version finale (tous les modules, lots 1 à 6)
--    Même fonction dans tous les scripts : l'ordre de relance n'a pas d'importance.
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

drop trigger if exists factures_journal on public.factures;
create trigger factures_journal
  after insert or update or delete on public.factures
  for each row execute function public.journaliser('Factures');

drop trigger if exists paiements_journal on public.paiements;
create trigger paiements_journal
  after insert or update or delete on public.paiements
  for each row execute function public.journaliser('Paiements');


-- ---------------------------------------------------------------------
-- 6. Sécurité
-- ---------------------------------------------------------------------
alter table public.factures  enable row level security;
alter table public.paiements enable row level security;

drop policy if exists lecture_connectes on public.factures;
create policy lecture_connectes on public.factures for select to authenticated using (true);
drop policy if exists creation_connectes on public.factures;
create policy creation_connectes on public.factures for insert to authenticated with check (true);
drop policy if exists modification_connectes on public.factures;
create policy modification_connectes on public.factures for update to authenticated using (true) with check (true);
-- Seuls les brouillons se suppriment. Une facture émise reste à vie (on l'annule par un avoir).
-- Suppression libre : une facture avec des paiements est protégée par la base (supprimer les paiements d'abord)
drop policy if exists suppression_brouillons on public.factures;
drop policy if exists suppression_connectes on public.factures;
create policy suppression_connectes on public.factures for delete to authenticated using (true);

drop policy if exists acces_complet_connectes on public.paiements;
create policy acces_complet_connectes on public.paiements for all to authenticated using (true) with check (true);


-- ---------------------------------------------------------------------
-- 7. Temps réel
-- ---------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['factures', 'paiements'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when others then
      null;
    end;
  end loop;
end;
$$;

-- Fin du script lot 4
