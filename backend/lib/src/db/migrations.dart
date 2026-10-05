/// Migrações do banco de dados, aplicadas em ordem e registradas em
/// `schema_migrations`. Nunca altere uma migração já publicada: crie outra.
const migrations = <(int, String, String)>[
  (1, 'schema inicial', r'''
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  email text NOT NULL,
  cpf text,
  phone text,
  password_hash text,
  avatar_url text,
  super_admin boolean NOT NULL DEFAULT false,
  last_login_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX users_email_uq ON users (lower(email));
CREATE UNIQUE INDEX users_cpf_uq ON users (cpf) WHERE cpf IS NOT NULL;

CREATE TABLE refresh_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  revoked_at timestamptz,
  user_agent text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE password_resets (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE companies (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  legal_name text NOT NULL DEFAULT '',
  document_type text NOT NULL DEFAULT '1',
  document text NOT NULL DEFAULT '',
  cno_caepf text NOT NULL DEFAULT '',
  address text NOT NULL DEFAULT '',
  city text NOT NULL DEFAULT '',
  state text NOT NULL DEFAULT '',
  timezone text NOT NULL DEFAULT 'America/Sao_Paulo',
  utc_offset_minutes integer NOT NULL DEFAULT -180,
  settings jsonb NOT NULL DEFAULT '{}'::jsonb,
  last_nsr bigint NOT NULL DEFAULT 0,
  last_hash text NOT NULL DEFAULT '',
  qr_secret text NOT NULL DEFAULT encode(gen_random_bytes(24), 'hex'),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE departments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX departments_company_idx ON departments (company_id);

CREATE TABLE positions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  name text NOT NULL,
  description text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX positions_company_idx ON positions (company_id);

CREATE TABLE schedules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  name text NOT NULL,
  definition jsonb NOT NULL,
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX schedules_company_idx ON schedules (company_id);

CREATE TABLE members (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role text NOT NULL DEFAULT 'employee',
  registration text,
  department_id uuid REFERENCES departments(id) ON DELETE SET NULL,
  position_id uuid REFERENCES positions(id) ON DELETE SET NULL,
  schedule_id uuid REFERENCES schedules(id) ON DELETE SET NULL,
  manager_id uuid REFERENCES members(id) ON DELETE SET NULL,
  admission_date date,
  dismissal_date date,
  active boolean NOT NULL DEFAULT true,
  pin_hash text,
  badge_code text,
  allow_anywhere boolean NOT NULL DEFAULT false,
  photo_url text,
  esocial_registration text,
  initial_bank_minutes integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, user_id)
);
CREATE INDEX members_company_idx ON members (company_id);
CREATE UNIQUE INDEX members_badge_uq ON members (company_id, badge_code) WHERE badge_code IS NOT NULL;

CREATE TABLE geofences (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  name text NOT NULL,
  lat double precision NOT NULL,
  lng double precision NOT NULL,
  radius double precision NOT NULL DEFAULT 150,
  address text NOT NULL DEFAULT '',
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX geofences_company_idx ON geofences (company_id);

CREATE TABLE member_geofences (
  member_id uuid NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  geofence_id uuid NOT NULL REFERENCES geofences(id) ON DELETE CASCADE,
  PRIMARY KEY (member_id, geofence_id)
);

CREATE TABLE holidays (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  date date NOT NULL,
  name text NOT NULL,
  scope text NOT NULL DEFAULT 'company',
  recurring boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX holidays_company_date_idx ON holidays (company_id, date);

CREATE TABLE devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  name text NOT NULL,
  geofence_id uuid REFERENCES geofences(id) ON DELETE SET NULL,
  token_hash text,
  activation_code text,
  activation_expires_at timestamptz,
  active boolean NOT NULL DEFAULT true,
  platform text,
  last_seen_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX devices_company_idx ON devices (company_id);
CREATE UNIQUE INDEX devices_activation_uq ON devices (activation_code) WHERE activation_code IS NOT NULL;

CREATE TABLE files (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid REFERENCES companies(id) ON DELETE CASCADE,
  uploaded_by uuid REFERENCES users(id) ON DELETE SET NULL,
  filename text NOT NULL,
  content_type text NOT NULL,
  size integer NOT NULL,
  sha256 text NOT NULL,
  path text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Marcações (registro tipo 7 do AFD). Registros originais são imutáveis:
-- o tratamento usa as colunas disregarded_* e inclusões com origin <> 'O'.
CREATE TABLE punches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  member_id uuid NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  nsr bigint,
  punched_at timestamptz NOT NULL,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  source text NOT NULL DEFAULT 'mobile',
  method text NOT NULL DEFAULT 'app',
  origin text NOT NULL DEFAULT 'O',
  offline boolean NOT NULL DEFAULT false,
  lat double precision,
  lng double precision,
  accuracy double precision,
  inside_geofence boolean,
  geofence_id uuid REFERENCES geofences(id) ON DELETE SET NULL,
  distance double precision,
  photo_file_id uuid REFERENCES files(id) ON DELETE SET NULL,
  device_id uuid REFERENCES devices(id) ON DELETE SET NULL,
  hash text,
  client_id text,
  ip text,
  user_agent text,
  note text,
  disregarded boolean NOT NULL DEFAULT false,
  disregard_reason text,
  disregarded_by uuid REFERENCES members(id) ON DELETE SET NULL,
  created_by uuid REFERENCES members(id) ON DELETE SET NULL,
  request_id uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX punches_member_time_idx ON punches (member_id, punched_at);
CREATE INDEX punches_company_time_idx ON punches (company_id, punched_at);
CREATE UNIQUE INDEX punches_company_nsr_uq ON punches (company_id, nsr) WHERE nsr IS NOT NULL;
CREATE UNIQUE INDEX punches_client_uq ON punches (member_id, client_id) WHERE client_id IS NOT NULL;

-- Eventos do REP (registros tipo 2 e 5 do AFD).
CREATE TABLE rep_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  nsr bigint NOT NULL,
  type smallint NOT NULL,
  operation text,
  member_id uuid REFERENCES members(id) ON DELETE SET NULL,
  cpf text,
  name text,
  responsible_cpf text,
  recorded_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (company_id, nsr)
);

CREATE TABLE requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  member_id uuid NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  type text NOT NULL,
  status text NOT NULL DEFAULT 'pending',
  date date NOT NULL,
  end_date date,
  times text[] NOT NULL DEFAULT '{}',
  minutes integer,
  reason text NOT NULL DEFAULT '',
  attachment_file_id uuid REFERENCES files(id) ON DELETE SET NULL,
  reviewer_id uuid REFERENCES members(id) ON DELETE SET NULL,
  reviewed_at timestamptz,
  review_note text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX requests_company_status_idx ON requests (company_id, status, created_at DESC);

CREATE TABLE absences (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  member_id uuid NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  type text NOT NULL,
  start_date date NOT NULL,
  end_date date NOT NULL,
  minutes_per_day integer,
  reason text NOT NULL DEFAULT '',
  attachment_file_id uuid REFERENCES files(id) ON DELETE SET NULL,
  request_id uuid REFERENCES requests(id) ON DELETE SET NULL,
  created_by uuid REFERENCES members(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX absences_member_idx ON absences (member_id, start_date, end_date);

CREATE TABLE bank_entries (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  member_id uuid NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  date date NOT NULL,
  minutes integer NOT NULL,
  type text NOT NULL,
  description text NOT NULL DEFAULT '',
  created_by uuid REFERENCES members(id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX bank_entries_member_idx ON bank_entries (member_id, date);

CREATE TABLE timesheet_signatures (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  member_id uuid NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  period text NOT NULL,
  hash text NOT NULL,
  agreed boolean NOT NULL DEFAULT true,
  comment text,
  ip text,
  signed_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (member_id, period)
);

CREATE TABLE messages (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  from_member_id uuid NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  to_member_id uuid NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  body text NOT NULL,
  attachment_file_id uuid REFERENCES files(id) ON DELETE SET NULL,
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX messages_pair_idx ON messages (company_id, from_member_id, to_member_id, created_at);
CREATE INDEX messages_to_unread_idx ON messages (to_member_id) WHERE read_at IS NULL;

CREATE TABLE notes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id uuid NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  title text NOT NULL DEFAULT '',
  body text NOT NULL DEFAULT '',
  pinned boolean NOT NULL DEFAULT false,
  color text NOT NULL DEFAULT 'default',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX notes_member_idx ON notes (member_id);

CREATE TABLE notifications (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  member_id uuid NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  title text NOT NULL,
  body text NOT NULL DEFAULT '',
  type text NOT NULL DEFAULT 'info',
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX notifications_member_idx ON notifications (member_id, created_at DESC);

CREATE TABLE audit_logs (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid REFERENCES companies(id) ON DELETE CASCADE,
  user_id uuid REFERENCES users(id) ON DELETE SET NULL,
  action text NOT NULL,
  entity text NOT NULL,
  entity_id text,
  data jsonb NOT NULL DEFAULT '{}'::jsonb,
  ip text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_company_idx ON audit_logs (company_id, created_at DESC);
'''),
  (2, 'fechamento de período', r'''
CREATE TABLE period_closings (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  company_id uuid NOT NULL REFERENCES companies(id) ON DELETE CASCADE,
  start_date date NOT NULL,
  end_date date NOT NULL,
  closed_by uuid REFERENCES members(id) ON DELETE SET NULL,
  note text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (end_date >= start_date)
);
CREATE INDEX period_closings_company_idx ON period_closings (company_id, start_date, end_date);
'''),
];
