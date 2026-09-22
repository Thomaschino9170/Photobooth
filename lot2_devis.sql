-- =====================================================================
--  FlashBox CRM — Lot 2 : devis
--  Prérequis : lot1_socle.sql déjà exécuté.
--  À coller dans Supabase > SQL Editor > New query, puis "Run".
--  Le script peut être relancé sans risque : il n'efface aucune donnée.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Journal : on ajoute une colonne "details" (ex. le nouveau statut d'un devis)
-- ---------------------------------------------------------------------
alter table public.journal add column if not exists details text;


-- ---------------------------------------------------------------------
-- 2. Tables
-- ---------------------------------------------------------------------

-- Les devis. Le contenu (lignes) est stocké d'un bloc au format JSON.
create table if not exists public.devis (
  id              uuid primary key default gen_random_uuid(),
  annee           integer not null,               -- année du devis (2026 -> affichée 0026)
  numero          integer not null,               -- numéro dans l'année, attribué automatiquement
  version         integer not null default 1,     -- indice : 1 = A, 2 = B…
  reference       text not null,                  -- DV-0026-014-A, figée à la création
  client_id       uuid not null references public.clients(id) on delete restrict,
  statut          text not null default 'brouillon'
                  check (statut in ('brouillon', 'envoye', 'accepte', 'refuse', 'remplace')),
  objet           text,
  evenement_type  text,
  date_evenement  date,
  heure_debut     time,
  heure_fin       time,
  lieu_nom        text,
  lieu_adresse    text,
  lieu_cp         text,
  lieu_ville      text,
  nb_invites      integer,
  preambule       text,
  lignes          jsonb not null default '[]'::jsonb,
  remise_type     text not null default '%' check (remise_type in ('%', '€')),
  remise_valeur   numeric(10,2) not null default 0,
  acompte_pct     numeric(5,2) not null default 30,
  validite_jours  integer not null default 30,
  conditions      text,
  notes_internes  text,
  total           numeric(10,2) not null default 0,
  date_devis      date not null default current_date,
  date_envoi      timestamptz,
  date_relance    timestamptz,
  date_reponse    timestamptz,
  remplace_par    uuid,
  etabli_par      text default public.email_courant(),
  created_at      timestamptz not null default now(),
  created_by      text default public.email_courant(),
  updated_at      timestamptz not null default now(),
  updated_by      text default public.email_courant(),
  constraint devis_numero_version unique (annee, numero, version)
);
create index if not exists devis_client_idx on public.devis (client_id);

-- Mise à jour d'une base créée avant la numérotation annuelle
alter table public.devis add column if not exists annee integer;
update public.devis set annee = extract(year from coalesce(date_devis, created_at::date))::integer where annee is null;
alter table public.devis alter column annee set not null;
-- L'unicité porte désormais sur année + numéro + indice
alter table public.devis drop constraint if exists devis_numero_version;
alter table public.devis add constraint devis_numero_version unique (annee, numero, version);
create index if not exists devis_statut_idx on public.devis (statut);

-- Les modèles de devis (devis types à copier)
create table if not exists public.devis_types (
  id              uuid primary key default gen_random_uuid(),
  nom             text not null,
  objet           text,
  evenement_type  text,
  preambule       text,
  lignes          jsonb not null default '[]'::jsonb,
  remise_type     text not null default '%' check (remise_type in ('%', '€')),
  remise_valeur   numeric(10,2) not null default 0,
  created_at      timestamptz not null default now(),
  created_by      text default public.email_courant(),
  updated_at      timestamptz not null default now(),
  updated_by      text default public.email_courant()
);


-- ---------------------------------------------------------------------
-- 3. Paramètres et modèles de départ (seulement s'ils n'existent pas)
-- ---------------------------------------------------------------------
insert into public.parametres (cle, valeur) values
  ('devis', '{
     "prefixe": "DV", "chiffres": 3, "prochain_numero": 1,
     "acompte_pct": 30, "validite_jours": 30, "relance_jours": 7,
     "conditions": "Devis valable {validite} jours à compter de sa date d’émission.\nUn acompte de {acompte} % du montant total est demandé à la signature pour réserver la date. Le solde est à régler au plus tard le jour de la prestation.\nRèglement par virement bancaire ou en espèces.\nLa prestation comprend la livraison, l’installation et la récupération du matériel.",
     "message_envoi": "Bonjour {prenom},\n\nVoici notre devis {reference} pour {evenement}.\nN’hésitez pas à nous contacter pour toute question.\n\nÀ bientôt,\n{expediteur} – {entreprise}"
   }'),
  ('catalogue', '[
     {"categorie": "Formule", "libelle": "Formule Essentielle", "description": "3 h de location, borne photo, accessoires, impressions illimitées", "prix": 290, "unite": "forfait"},
     {"categorie": "Formule", "libelle": "Formule Mariage", "description": "5 h de location, toile de fond au choix, tirages personnalisés, galerie numérique, livre d’or photo", "prix": 490, "unite": "forfait"},
     {"categorie": "Formule", "libelle": "Formule Entreprise", "description": "Habillage aux couleurs de la marque, écran d’accueil personnalisé, animation sur mesure, bilan des participations", "prix": 690, "unite": "forfait"},
     {"categorie": "Option", "libelle": "Heure supplémentaire", "description": "", "prix": 60, "unite": "heure"},
     {"categorie": "Option", "libelle": "Livre d’or photo", "description": "Un tirage collé et un mot de chaque invité", "prix": 40, "unite": "forfait"},
     {"categorie": "Option", "libelle": "Toile de fond personnalisée", "description": "", "prix": 50, "unite": "forfait"},
     {"categorie": "Option", "libelle": "Galerie numérique en ligne", "description": "Toutes les photos en haute définition", "prix": 30, "unite": "forfait"},
     {"categorie": "Option", "libelle": "Animateur sur place", "description": "", "prix": 35, "unite": "heure"},
     {"categorie": "Déplacement", "libelle": "Frais de déplacement", "description": "Aller-retour depuis Deuil-la-Barre", "prix": 0.6, "unite": "km"}
   ]'),
  ('types_evenement', '["Mariage", "Anniversaire", "Soirée d’entreprise", "Baptême / communion", "Fête associative", "Salon / séminaire", "Autre"]')
on conflict (cle) do nothing;

insert into public.devis_types (nom, objet, evenement_type, preambule, lignes)
select v.nom, v.objet, v.evenement_type, v.preambule, v.lignes::jsonb
from (values
  ('Anniversaire 3 h', 'Animation photobooth pour votre anniversaire', 'Anniversaire',
   'Merci pour votre demande ! Voici notre proposition pour une fête pleine de souvenirs.',
   '[{"libelle": "Formule Essentielle", "description": "3 h de location, borne photo, accessoires, impressions illimitées", "quantite": 1, "prix_unitaire": 290, "unite": "forfait"}]'),
  ('Mariage 5 h', 'Animation photobooth pour votre mariage', 'Mariage',
   'Merci pour votre demande ! Voici notre proposition pour immortaliser votre mariage.',
   '[{"libelle": "Formule Mariage", "description": "5 h de location, toile de fond au choix, tirages personnalisés, galerie numérique, livre d’or photo", "quantite": 1, "prix_unitaire": 490, "unite": "forfait"}]'),
  ('Soirée d’entreprise', 'Animation photobooth pour votre événement d’entreprise', 'Soirée d’entreprise',
   'Merci pour votre demande. Voici notre proposition pour animer votre événement.',
   '[{"libelle": "Formule Entreprise", "description": "Habillage aux couleurs de la marque, écran d’accueil personnalisé, animation sur mesure, bilan des participations", "quantite": 1, "prix_unitaire": 690, "unite": "forfait"}, {"libelle": "Animateur sur place", "description": "", "quantite": 4, "prix_unitaire": 35, "unite": "heure"}]')
) as v(nom, objet, evenement_type, preambule, lignes)
where not exists (select 1 from public.devis_types);


-- ---------------------------------------------------------------------
-- 4. Numérotation automatique : DV-0026-014-A
--    Nouveau devis                 -> numéro suivant de l'année, indice A
--    Nouvel indice d'un devis      -> même numéro, indice suivant (B, C…)
-- ---------------------------------------------------------------------
-- 1 -> A, 2 -> B … 27 -> AA
create or replace function public.indice_lettre(n integer)
returns text
language plpgsql
immutable
as $$
declare
  v_reste integer := greatest(coalesce(n, 1), 1);
  v_txt   text := '';
begin
  while v_reste > 0 loop
    v_reste := v_reste - 1;
    v_txt := chr(65 + (v_reste % 26)) || v_txt;
    v_reste := v_reste / 26;
  end loop;
  return v_txt;
end;
$$;

create or replace function public.numeroter_devis()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_conf      jsonb;
  v_prefixe   text;
  v_chiffres  integer;
  v_prochain  integer;
begin
  -- Verrou : deux associés qui créent un devis en même temps n'auront pas le même numéro
  perform pg_advisory_xact_lock(hashtext('flashbox_numerotation_devis'));

  select valeur into v_conf from public.parametres where cle = 'devis';
  v_prefixe  := coalesce(nullif(v_conf ->> 'prefixe', ''), 'DV');
  v_chiffres := coalesce((v_conf ->> 'chiffres')::integer, 3);
  v_prochain := coalesce((v_conf ->> 'prochain_numero')::integer, 1);

  new.annee := coalesce(new.annee, extract(year from coalesce(new.date_devis, current_date))::integer);

  if new.numero is null then
    select greatest(coalesce(max(numero), 0) + 1, v_prochain) into new.numero
    from public.devis where annee = new.annee;
    new.version := 1;
  else
    select coalesce(max(version), 0) + 1 into new.version
    from public.devis where annee = new.annee and numero = new.numero;
  end if;

  new.reference := v_prefixe
    || '-' || lpad((new.annee % 100)::text, 4, '0')
    || '-' || case when length(new.numero::text) >= v_chiffres then new.numero::text
                   else lpad(new.numero::text, v_chiffres, '0') end
    || '-' || public.indice_lettre(new.version);
  return new;
end;
$$;

drop trigger if exists devis_numerotation on public.devis;
create trigger devis_numerotation
  before insert on public.devis
  for each row execute function public.numeroter_devis();

-- Le numéro, la version et la référence ne peuvent plus changer ensuite
create or replace function public.figer_reference_devis()
returns trigger
language plpgsql
as $$
begin
  new.annee      := old.annee;
  new.numero     := old.numero;
  new.version    := old.version;
  new.reference  := old.reference;
  new.created_at := old.created_at;
  new.created_by := old.created_by;
  return new;
end;
$$;

drop trigger if exists devis_figer on public.devis;
create trigger devis_figer
  before update on public.devis
  for each row execute function public.figer_reference_devis();

drop trigger if exists devis_horodatage on public.devis;
create trigger devis_horodatage
  before update on public.devis
  for each row execute function public.maj_horodatage();

drop trigger if exists devis_types_horodatage on public.devis_types;
create trigger devis_types_horodatage
  before update on public.devis_types
  for each row execute function public.maj_horodatage();


-- ---------------------------------------------------------------------
-- 5. Journal : version enrichie (devis + changements de statut)
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

drop trigger if exists devis_journal on public.devis;
create trigger devis_journal
  after insert or update or delete on public.devis
  for each row execute function public.journaliser('Devis');

drop trigger if exists devis_types_journal on public.devis_types;
create trigger devis_types_journal
  after insert or update or delete on public.devis_types
  for each row execute function public.journaliser('Modèles de devis');


-- ---------------------------------------------------------------------
-- 6. Sécurité
-- ---------------------------------------------------------------------
alter table public.devis       enable row level security;
alter table public.devis_types enable row level security;

drop policy if exists lecture_connectes on public.devis;
create policy lecture_connectes on public.devis
  for select to authenticated using (true);

drop policy if exists creation_connectes on public.devis;
create policy creation_connectes on public.devis
  for insert to authenticated with check (true);

drop policy if exists modification_connectes on public.devis;
create policy modification_connectes on public.devis
  for update to authenticated using (true) with check (true);

-- Seuls les brouillons peuvent être supprimés (un devis envoyé reste dans l'historique)
drop policy if exists suppression_brouillons on public.devis;
create policy suppression_brouillons on public.devis
  for delete to authenticated using (statut = 'brouillon');

drop policy if exists acces_complet_connectes on public.devis_types;
create policy acces_complet_connectes on public.devis_types
  for all to authenticated using (true) with check (true);


-- ---------------------------------------------------------------------
-- 7. Temps réel
-- ---------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array['devis', 'devis_types'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when others then
      null;
    end;
  end loop;
end;
$$;

-- Fin du script lot 2
