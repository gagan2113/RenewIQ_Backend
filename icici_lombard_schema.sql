-- =============================================================================
--  RenewIQ — ICICI Lombard General Insurance
--  PostgreSQL Schema  ·  v3.0  ·  Aligned to IL_RenewIQ_3Customers.xlsx
--  Updated : 2026-03-20
--
--  Changes from v2.0:
--  • customers  : added aadhaar_last4 column (was missing); UUID format aligned
--                 to CUST-XX-NNN readable IDs; added customer display_name helper
--  • policies   : added rm_id column; days_to_expiry computed column added;
--                 gst_amount / total_premium precision matched to file (NUMERIC 12,2);
--                 policy_uuid format aligned to POL-XX-XXXX
--  • il_health_details : added customer_name denorm helper (for API responses);
--                 ncb_percent renamed ncb_pct to match motor table; ayush_covered added
--  • il_motor_details  : ncb stored as INTEGER not NUMERIC (file shows 20 not 20.00);
--                 ncb_certificate_no → ncb_cert_no (shorter, matches file col header);
--                 pa_cover_owner / nil_depreciation / rsa_cover stored as BOOLEAN
--  • campaigns  : id is now VARCHAR(30) not UUID to match CAMP-DEC25-001 format;
--                 primary_channel + fallback_1 + fallback_2 columns added (denorm
--                 for simple lookups matching file structure)
--  • reminders  : added customer_name VARCHAR for display; is_fallback removed
--                 (replaced by attempt_number > 1 logic); 12 columns match file exactly
--  • whatsapp_logs : button_clicked → button_label; reply_text kept; meta_message_id
--                 format length extended to 50
--  • sms_logs   : error_code column kept; opted_out moved to customers table only
--  • email_logs : open_count / click_count are SMALLINT (max 99); subject increased
--                 to VARCHAR(300) to fit long subjects in file
--  • renewal_tokens : short_code & short_url + customer_name added; token_hash
--                 kept separate (not in file — stored internally, never exposed)
--  • payments   : gateway_order_id / gateway_txn_id lengths increased to VARCHAR(50);
--                 customer_name denorm added; renewed_from/to are DATE columns
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- =============================================================================
-- §1  REFERENCE TABLES
-- =============================================================================

-- 1.1  IL Product Catalogue
CREATE TABLE il_products (
    id                  SMALLSERIAL     PRIMARY KEY,
    product_code        VARCHAR(30)     NOT NULL UNIQUE,   -- IHEALTH_FAM, MOTOR_PC …
    product_name        VARCHAR(150)    NOT NULL,
    product_line        VARCHAR(20)     NOT NULL
                        CHECK (product_line IN
                            ('HEALTH','MOTOR','TRAVEL','HOME','COMMERCIAL','LIFE')),
    policy_prefix       VARCHAR(10)     NOT NULL,          -- 4128, 3001, 4003 …
    sub_type            VARCHAR(50),
    min_tenure_days     SMALLINT        NOT NULL DEFAULT 365,
    max_tenure_days     SMALLINT        NOT NULL DEFAULT 365,
    gst_rate            NUMERIC(5,2)    NOT NULL DEFAULT 18.00,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_products IS
    'ICICI Lombard product catalogue — codes match Excel product_code column';

-- 1.2  Channels  (WHATSAPP / SMS / EMAIL / VOICE — exact values used in Excel)
CREATE TABLE channels (
    id                  SMALLSERIAL     PRIMARY KEY,
    code                VARCHAR(20)     NOT NULL UNIQUE,
    label               VARCHAR(50)     NOT NULL,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    default_wait_hrs    SMALLINT        NOT NULL DEFAULT 24,
    daily_limit         INT             NOT NULL DEFAULT 10000,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- 1.3  Languages
CREATE TABLE languages (
    id                  SMALLSERIAL     PRIMARY KEY,
    code                VARCHAR(10)     NOT NULL UNIQUE,   -- hi, en, mr …
    label               VARCHAR(50)     NOT NULL,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE
);

-- 1.4  Message Templates
CREATE TABLE message_templates (
    id                  SERIAL          PRIMARY KEY,
    channel_id          SMALLINT        NOT NULL REFERENCES channels(id),
    language_id         SMALLINT        NOT NULL REFERENCES languages(id),
    product_line        VARCHAR(20)
                        CHECK (product_line IN
                            ('HEALTH','MOTOR','TRAVEL','HOME','COMMERCIAL','LIFE','ALL')),
    reminder_window     VARCHAR(10)     NOT NULL
                        CHECK (reminder_window IN ('30DAY','15DAY','7DAY','3DAY')),
    -- template_code matches Excel "Template Name" column values
    -- e.g. il_health_expiry_hi_30d, il_health_urgent_hi_15d, il_motor_renewal_en_15d
    template_code       VARCHAR(100)    NOT NULL UNIQUE,
    subject             VARCHAR(300),                      -- email: full subject line from file
    body_text           TEXT            NOT NULL,
    dlt_template_id     VARCHAR(50),                       -- SMS: 1107165432987612 from Excel
    meta_template_name  VARCHAR(100),                      -- WhatsApp HSM
    is_approved         BOOLEAN         NOT NULL DEFAULT FALSE,
    version             SMALLINT        NOT NULL DEFAULT 1,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    UNIQUE (channel_id, language_id, product_line, reminder_window, version)
);

CREATE INDEX idx_templates_lookup ON message_templates(channel_id, reminder_window, product_line);

-- =============================================================================
-- §2  IL GEOGRAPHY
-- =============================================================================

CREATE TABLE il_zones (
    id          SMALLSERIAL  PRIMARY KEY,
    zone_code   VARCHAR(10)  NOT NULL UNIQUE,
    zone_name   VARCHAR(60)  NOT NULL,
    hq_city     VARCHAR(80),
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE il_regions (
    id           SMALLSERIAL  PRIMARY KEY,
    zone_id      SMALLINT     NOT NULL REFERENCES il_zones(id),
    region_code  VARCHAR(15)  NOT NULL UNIQUE,
    region_name  VARCHAR(80)  NOT NULL,
    hq_city      VARCHAR(80),
    is_active    BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_regions_zone ON il_regions(zone_id);

-- branches — branch_code values used in Excel: BR_IND001, BR_BHU001, BR_NAG001
CREATE TABLE il_branches (
    id           SERIAL       PRIMARY KEY,
    region_id    SMALLINT     NOT NULL REFERENCES il_regions(id),
    branch_code  VARCHAR(20)  NOT NULL UNIQUE,  -- BR_IND001 / BR_BHU001 / BR_NAG001
    branch_name  VARCHAR(150) NOT NULL,
    city         VARCHAR(80)  NOT NULL,
    state        VARCHAR(80)  NOT NULL,
    pincode      VARCHAR(10),
    address      TEXT,
    phone        VARCHAR(20),
    email        VARCHAR(150),
    is_active    BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
COMMENT ON COLUMN il_branches.branch_code IS
    'Used as FK reference in policies.branch_code — matches Excel Branch column';
CREATE INDEX idx_branches_region ON il_branches(region_id);
CREATE INDEX idx_branches_code   ON il_branches(branch_code);

-- =============================================================================
-- §3  AGENT HIERARCHY  (TM → SM → RM → Agent)
-- =============================================================================

CREATE TABLE il_territory_managers (
    id             UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    branch_id      INT          NOT NULL REFERENCES il_branches(id),
    employee_code  VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(150) NOT NULL,
    email          VARCHAR(150) NOT NULL UNIQUE,
    phone          VARCHAR(20),
    is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
    joined_on      DATE,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE TABLE il_sales_managers (
    id             UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    tm_id          UUID         NOT NULL REFERENCES il_territory_managers(id),
    branch_id      INT          NOT NULL REFERENCES il_branches(id),
    employee_code  VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(150) NOT NULL,
    email          VARCHAR(150) NOT NULL UNIQUE,
    phone          VARCHAR(20),
    is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
    joined_on      DATE,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_sm_tm ON il_sales_managers(tm_id);

CREATE TABLE il_relationship_managers (
    id             UUID         PRIMARY KEY DEFAULT gen_random_uuid(),
    sm_id          UUID         NOT NULL REFERENCES il_sales_managers(id),
    branch_id      INT          NOT NULL REFERENCES il_branches(id),
    -- rm_id referenced in policies as RM004, RM005 — store as employee_code
    employee_code  VARCHAR(20)  NOT NULL UNIQUE,   -- RM004, RM005 …
    full_name      VARCHAR(150) NOT NULL,
    email          VARCHAR(150) NOT NULL UNIQUE,
    phone          VARCHAR(20),
    is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
    joined_on      DATE,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_rm_sm ON il_relationship_managers(sm_id);

-- il_agents — agent_code values in Excel: AG007, AG015, AG023
CREATE TABLE il_agents (
    id                UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    rm_id             UUID        REFERENCES il_relationship_managers(id),
    branch_id         INT         NOT NULL REFERENCES il_branches(id),
    agent_code        VARCHAR(30) NOT NULL UNIQUE,   -- AG007, AG015, AG023
    irdai_licence_no  VARCHAR(30) NOT NULL UNIQUE,
    full_name         VARCHAR(150) NOT NULL,
    email             VARCHAR(150),
    phone             VARCHAR(20) NOT NULL,
    agent_type        VARCHAR(20) NOT NULL DEFAULT 'INDIVIDUAL'
                      CHECK (agent_type IN ('INDIVIDUAL','CORPORATE','BANK','BROKER')),
    specialisation    VARCHAR(20)[] DEFAULT '{}',
    licence_expiry    DATE,
    is_active         BOOLEAN     NOT NULL DEFAULT TRUE,
    joined_on         DATE,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON COLUMN il_agents.agent_code IS
    'Matches Excel Agent column values: AG007, AG015, AG023';
CREATE INDEX idx_agents_rm     ON il_agents(rm_id);
CREATE INDEX idx_agents_branch ON il_agents(branch_id);
CREATE INDEX idx_agents_code   ON il_agents(agent_code);

-- =============================================================================
-- §4  CUSTOMERS
-- Columns match Excel 🧑 Customers sheet exactly (20 columns)
-- =============================================================================

CREATE TABLE customers (
    -- PK: readable format matching Excel — CUST-GV-001, CUST-AU-002, CUST-KG-003
    id                    VARCHAR(30)   PRIMARY KEY,

    -- IL CRM system ID — IL78430159, IL92745600, IL62613248
    il_customer_id        VARCHAR(30)   UNIQUE,

    first_name            VARCHAR(80)   NOT NULL,
    last_name             VARCHAR(80)   NOT NULL,

    -- helper: first_name || ' ' || last_name — used in reminder/payment display
    display_name          VARCHAR(170)  GENERATED ALWAYS AS
                              (first_name || ' ' || last_name) STORED,

    date_of_birth         DATE,
    gender                CHAR(1)       CHECK (gender IN ('M','F','O')),

    -- PAN for 80D tax certificates — ABJPV4821K, CMNPU3742H, FKRPG5194M
    pan_number            VARCHAR(10),

    -- Excel column: "Aadhaar Last 4" — 7823, 4561, 3197
    aadhaar_last4         CHAR(4),

    email                 VARCHAR(150),
    phone                 VARCHAR(20)   NOT NULL,   -- +919893010159 format
    whatsapp_number       VARCHAR(20),              -- same as phone for all 3 in file

    city                  VARCHAR(80),
    state                 VARCHAR(80),
    pincode               VARCHAR(10),

    -- Excel col: "Pref Channel" — WHATSAPP / EMAIL
    preferred_channel_id  SMALLINT      REFERENCES channels(id),

    -- Excel col: "Pref Language" — hi / en
    preferred_language_id SMALLINT      REFERENCES languages(id),

    -- Excel col: "Segment" — GOLD, SILVER, STANDARD
    customer_segment      VARCHAR(20)
                          CHECK (customer_segment IN
                              ('PLATINUM','GOLD','SILVER','STANDARD')),

    -- Excel col: "KYC Status" — VERIFIED for all 3
    kyc_status            VARCHAR(20)   NOT NULL DEFAULT 'PENDING'
                          CHECK (kyc_status IN
                              ('PENDING','VERIFIED','REJECTED','EXPIRED')),
    kyc_verified_at       TIMESTAMPTZ,

    -- Excel col: "Is NRI" — No for all 3
    is_nri                BOOLEAN       NOT NULL DEFAULT FALSE,

    -- Excel col: "Is Opted Out" — No for all 3
    is_opted_out          BOOLEAN       NOT NULL DEFAULT FALSE,
    opted_out_at          TIMESTAMPTZ,

    created_at            TIMESTAMPTZ   NOT NULL DEFAULT NOW(),
    updated_at            TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE customers IS
    'Primary key format: CUST-GV-001 style (readable). Matches Excel UUID column exactly.';

CREATE INDEX idx_customers_phone     ON customers(phone);
CREATE INDEX idx_customers_email     ON customers(email);
CREATE INDEX idx_customers_il_id     ON customers(il_customer_id);
CREATE INDEX idx_customers_segment   ON customers(customer_segment);
CREATE INDEX idx_customers_active    ON customers(is_opted_out) WHERE is_opted_out = FALSE;
CREATE INDEX idx_customers_name_trgm ON customers
    USING GIN (display_name gin_trgm_ops);

-- =============================================================================
-- §5  POLICIES
-- 20 columns match Excel 📋 Policies sheet exactly
-- =============================================================================

CREATE TABLE policies (
    -- PK: readable format — POL-GV-H001, POL-AU-M001, POL-KG-H001
    id                  VARCHAR(30)     PRIMARY KEY,

    -- IL policy number — 4128/2024/83040159, 3001/2024/76745600, 4128/2025/61397248
    il_policy_number    VARCHAR(30)     NOT NULL UNIQUE,

    -- FK to customers.id — CUST-GV-001, CUST-AU-002, CUST-KG-003
    customer_id         VARCHAR(30)     NOT NULL REFERENCES customers(id) ON DELETE CASCADE,

    -- FK to il_products.product_code — IHEALTH_FAM, MOTOR_PC, IHEALTH_IND
    product_code        VARCHAR(30)     NOT NULL REFERENCES il_products(product_code),

    -- Denorm for fast filtering — HEALTH, MOTOR
    product_line        VARCHAR(20)     NOT NULL
                        CHECK (product_line IN
                            ('HEALTH','MOTOR','TRAVEL','HOME','COMMERCIAL','LIFE')),

    -- Excel col: "Branch" — BR_IND001, BR_BHU001, BR_NAG001
    branch_code         VARCHAR(20)     NOT NULL REFERENCES il_branches(branch_code),

    -- Excel col: "Agent" — AG007, AG015, AG023
    agent_code          VARCHAR(30)     REFERENCES il_agents(agent_code),

    -- Excel col: "RM" — RM004, RM002, RM005
    rm_code             VARCHAR(20)     REFERENCES il_relationship_managers(employee_code),

    -- Coverage dates
    risk_start_date     DATE            NOT NULL,
    risk_end_date       DATE            NOT NULL,

    -- Computed: days remaining — matches Excel "Days to Expiry" column
    days_to_expiry      INTEGER         GENERATED ALWAYS AS
                            ((risk_end_date - CURRENT_DATE)::INTEGER) STORED,

    -- Financials — precision matches Excel values exactly
    sum_insured         NUMERIC(14,2)   NOT NULL CHECK (sum_insured > 0),
    net_premium         NUMERIC(12,2)   NOT NULL CHECK (net_premium > 0),
    gst_rate            NUMERIC(5,2)    NOT NULL DEFAULT 18.00,

    -- Computed — matches Excel: 13490 * 18% = 2428.20
    gst_amount          NUMERIC(12,2)   GENERATED ALWAYS AS
                            (ROUND(net_premium * gst_rate / 100, 2)) STORED,

    -- Computed — matches Excel: 13490 + 2428.20 = 15918.20
    total_premium       NUMERIC(12,2)   GENERATED ALWAYS AS
                            (net_premium + ROUND(net_premium * gst_rate / 100, 2)) STORED,

    -- Excel col: "Pay Mode" — ANNUAL for all 3
    payment_mode        VARCHAR(20)
                        CHECK (payment_mode IN
                            ('ANNUAL','HALF_YEARLY','QUARTERLY','MONTHLY','SINGLE')),

    -- Excel col: "Status" — EXPIRING for all 3
    policy_status       VARCHAR(20)     NOT NULL DEFAULT 'ACTIVE'
                        CHECK (policy_status IN
                            ('PROPOSAL','ACTIVE','EXPIRING','RENEWED',
                             'LAPSED','CANCELLED','SUSPENDED')),

    -- Excel col: "Renewal Count" — 3, 1, 0
    renewal_count       SMALLINT        NOT NULL DEFAULT 0,

    -- Excel col: "Is First Policy" — No, No, Yes
    is_first_policy     BOOLEAN         NOT NULL DEFAULT TRUE,

    issue_date          DATE            NOT NULL DEFAULT CURRENT_DATE,
    last_renewed_at     TIMESTAMPTZ,
    cancellation_reason TEXT,
    cancelled_at        TIMESTAMPTZ,

    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_risk_dates CHECK (risk_end_date > risk_start_date)
);
COMMENT ON TABLE policies IS
    'PK format: POL-GV-H001. days_to_expiry is computed daily — matches Excel Days to Expiry.';

CREATE INDEX idx_policies_customer    ON policies(customer_id);
CREATE INDEX idx_policies_product     ON policies(product_code);
CREATE INDEX idx_policies_product_line ON policies(product_line);
CREATE INDEX idx_policies_branch      ON policies(branch_code);
CREATE INDEX idx_policies_agent       ON policies(agent_code);
CREATE INDEX idx_policies_rm          ON policies(rm_code);
CREATE INDEX idx_policies_status      ON policies(policy_status);
-- Critical scheduler index — finds EXPIRING policies within 30-day window
CREATE INDEX idx_policies_expiry_scan ON policies(risk_end_date, policy_status)
    WHERE policy_status IN ('ACTIVE','EXPIRING');

-- =============================================================================
-- §6  PRODUCT-SPECIFIC EXTENSION TABLES  (1:1 with policies)
-- =============================================================================

-- 6.1  Health Details
-- 15 columns match Excel 🏥 Health Details sheet
CREATE TABLE il_health_details (
    policy_id               VARCHAR(30)     PRIMARY KEY
                            REFERENCES policies(id) ON DELETE CASCADE,

    -- Excel col: "Customer" — denorm display name
    customer_name           VARCHAR(170),

    -- Excel col: "Plan Variant" — FAMILY_FLOATER, INDIVIDUAL
    plan_variant            VARCHAR(20)
                            CHECK (plan_variant IN
                                ('INDIVIDUAL','FAMILY_FLOATER',
                                 'SENIOR_CITIZEN','GROUP')),

    -- Excel col: "Sum Insured Slab" — 5L, 3L
    sum_insured_slab        VARCHAR(10),

    -- Excel col: "Members Insured" — 3 (Gagan), 1 (Gourav)
    members_insured         SMALLINT        NOT NULL DEFAULT 1,

    -- Excel col: "Co-pay %" — 10 (Gagan), 0 (Gourav)
    copay_percent           NUMERIC(5,2)    NOT NULL DEFAULT 0,

    -- Excel col: "Room Rent Limit (₹)" — 5000, 3500
    room_rent_limit_inr     NUMERIC(10,2),

    -- Excel col: "Pre-existing Wait (days)" — 1095 (Gagan), 730 (Gourav)
    pre_existing_wait_days  SMALLINT        NOT NULL DEFAULT 1095,

    -- Excel col: "Maternity Covered" — Yes (Gagan), No (Gourav)
    maternity_covered       BOOLEAN         NOT NULL DEFAULT FALSE,
    maternity_wait_days     SMALLINT,

    -- Excel col: "NCB %" — 15 (Gagan), 0 (Gourav)
    ncb_pct                 NUMERIC(5,2)    NOT NULL DEFAULT 0,

    -- Excel col: "Cumulative Bonus %" — 10 (Gagan), 0 (Gourav)
    cumulative_bonus_pct    NUMERIC(5,2)    NOT NULL DEFAULT 0,

    -- Excel col: "Deductible (₹)" — 5000 (Gagan), 0 (Gourav)
    deductible_amount       NUMERIC(10,2)   NOT NULL DEFAULT 0,

    -- Excel col: "TPA ID" — TPA002 (Gagan), TPA001 (Gourav)
    tpa_id                  VARCHAR(30),

    -- Excel col: "Network Hospitals" — 9500 (Gagan), 8200 (Gourav)
    network_hospital_count  INT,

    -- Excel col: "COVID Covered" — Yes for both
    covid_covered           BOOLEAN         NOT NULL DEFAULT TRUE,

    -- Not in file but important — AYUSH coverage flag
    ayush_covered           BOOLEAN         NOT NULL DEFAULT FALSE,

    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_health_details IS
    '1:1 with policies. Columns match 🏥 Health Details Excel sheet exactly.';

-- 6.2  Motor Details
-- 18 columns match Excel 🚗 Motor Details sheet
CREATE TABLE il_motor_details (
    policy_id               VARCHAR(30)     PRIMARY KEY
                            REFERENCES policies(id) ON DELETE CASCADE,

    -- Excel col: "Customer" — denorm
    customer_name           VARCHAR(170),

    -- Excel col: "Vehicle Type" — PRIVATE_CAR
    vehicle_type            VARCHAR(20)     NOT NULL
                            CHECK (vehicle_type IN
                                ('PRIVATE_CAR','TWO_WHEELER','COMMERCIAL_VEHICLE',
                                 'TAXI','GOODS_VEHICLE')),

    -- Excel col: "Reg Number" — MP09CD4521
    registration_number     VARCHAR(20)     NOT NULL,

    -- Excel col: "Make" — Hyundai
    make                    VARCHAR(60)     NOT NULL,

    -- Excel col: "Model" — Creta
    model                   VARCHAR(80)     NOT NULL,

    -- Excel col: "Variant" — SX(O)
    variant                 VARCHAR(80),

    -- Excel col: "Manufacture Year" — 2022
    manufacture_year        SMALLINT        NOT NULL,

    -- Excel col: "Fuel Type" — PETROL
    fuel_type               VARCHAR(15)     NOT NULL
                            CHECK (fuel_type IN
                                ('PETROL','DIESEL','CNG','ELECTRIC','HYBRID')),

    -- Excel col: "Engine CC" — 1497
    engine_cc               SMALLINT,

    -- Excel col: "RTO Code" — MP09
    rto_code                VARCHAR(10)     NOT NULL,

    -- Excel col: "Policy Type" — COMPREHENSIVE
    policy_type             VARCHAR(15)     NOT NULL
                            CHECK (policy_type IN
                                ('COMPREHENSIVE','THIRD_PARTY','OWN_DAMAGE')),

    -- Excel col: "IDV (₹)" — 720000
    idv_amount              NUMERIC(12,2)   NOT NULL,

    -- Excel col: "NCB %" — 20  (stored as INTEGER — file shows 20 not 20.00)
    -- Valid IL NCB slabs: 0, 20, 25, 35, 45, 50
    ncb_percent             SMALLINT        NOT NULL DEFAULT 0
                            CHECK (ncb_percent IN (0,20,25,35,45,50)),

    -- Excel col: "NCB Certificate" — NCB203412
    ncb_cert_no             VARCHAR(30),

    -- Excel col: "PA Cover Owner" — Yes → stored as BOOLEAN
    pa_cover_owner          BOOLEAN         NOT NULL DEFAULT TRUE,

    -- Excel col: "Nil Depreciation" — Yes → BOOLEAN
    nil_depreciation        BOOLEAN         NOT NULL DEFAULT FALSE,

    -- Excel col: "RSA Cover" — Yes → BOOLEAN
    rsa_cover               BOOLEAN         NOT NULL DEFAULT FALSE,

    -- Additional fields not in file but needed for operations
    engine_number           VARCHAR(30),
    chassis_number          VARCHAR(30),
    seating_capacity        SMALLINT,
    hypothecation_bank      VARCHAR(100),
    pa_cover_amount         NUMERIC(10,2),

    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_motor_details IS
    '1:1 with policies. Columns match 🚗 Motor Details Excel sheet exactly.';

CREATE INDEX idx_motor_reg ON il_motor_details(registration_number);

-- 6.3  Travel Details (no data in file but kept for completeness)
CREATE TABLE il_travel_details (
    policy_id               VARCHAR(30)     PRIMARY KEY
                            REFERENCES policies(id) ON DELETE CASCADE,
    trip_type               VARCHAR(20)     NOT NULL
                            CHECK (trip_type IN
                                ('SINGLE_TRIP','MULTI_TRIP','STUDENT','SENIOR_CITIZEN')),
    travel_type             VARCHAR(15)     NOT NULL
                            CHECK (travel_type IN ('DOMESTIC','INTERNATIONAL')),
    destination_region      VARCHAR(50),
    departure_date          DATE            NOT NULL,
    return_date             DATE            NOT NULL,
    trip_duration_days      SMALLINT
                            GENERATED ALWAYS AS
                                ((return_date - departure_date)::SMALLINT) STORED,
    traveller_count         SMALLINT        NOT NULL DEFAULT 1,
    medical_cover_usd       NUMERIC(12,2),
    trip_cancellation_cover BOOLEAN         NOT NULL DEFAULT FALSE,
    baggage_loss_cover      BOOLEAN         NOT NULL DEFAULT FALSE,
    adventure_sports_cover  BOOLEAN         NOT NULL DEFAULT FALSE,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- 6.4  Home Details
CREATE TABLE il_home_details (
    policy_id               VARCHAR(30)     PRIMARY KEY
                            REFERENCES policies(id) ON DELETE CASCADE,
    property_type           VARCHAR(20)     NOT NULL
                            CHECK (property_type IN
                                ('OWNED_FLAT','OWNED_HOUSE','RENTED','UNDER_CONSTRUCTION')),
    construction_type       VARCHAR(20)     NOT NULL
                            CHECK (construction_type IN
                                ('RCC','SEMI_RCC','KATCHA','PREFABRICATED')),
    built_up_area_sqft      INT             NOT NULL,
    property_age_years      SMALLINT,
    property_address        TEXT            NOT NULL,
    property_city           VARCHAR(80)     NOT NULL,
    property_state          VARCHAR(80)     NOT NULL,
    property_pincode        VARCHAR(10)     NOT NULL,
    structure_cover_inr     NUMERIC(14,2),
    content_cover_inr       NUMERIC(12,2),
    jewellery_cover_inr     NUMERIC(10,2),
    earthquake_cover        BOOLEAN         NOT NULL DEFAULT TRUE,
    flood_cover             BOOLEAN         NOT NULL DEFAULT TRUE,
    burglary_cover          BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- 6.5  Commercial Details
CREATE TABLE il_commercial_details (
    policy_id               VARCHAR(30)     PRIMARY KEY
                            REFERENCES policies(id) ON DELETE CASCADE,
    commercial_type         VARCHAR(30)     NOT NULL
                            CHECK (commercial_type IN
                                ('FIRE','BURGLARY','MARINE_CARGO','LIABILITY',
                                 'WORKMEN_COMP','GROUP_HEALTH','SHOP_KEEPER',
                                 'OFFICE_PACKAGE','CYBER')),
    business_name           VARCHAR(200)    NOT NULL,
    gstin                   VARCHAR(20),
    industry_code           VARCHAR(10),
    premises_sqft           INT,
    employee_count          INT,
    annual_turnover_inr     NUMERIC(18,2),
    stock_value_inr         NUMERIC(16,2),
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- 6.6  Life Details
CREATE TABLE il_life_details (
    policy_id               VARCHAR(30)     PRIMARY KEY
                            REFERENCES policies(id) ON DELETE CASCADE,
    plan_type               VARCHAR(30)     NOT NULL
                            CHECK (plan_type IN
                                ('TERM','ENDOWMENT','ULIP','WHOLE_LIFE','MONEY_BACK')),
    sum_assured             NUMERIC(16,2)   NOT NULL,
    policy_term_years       SMALLINT        NOT NULL,
    premium_payment_term    SMALLINT        NOT NULL,
    death_benefit_option    VARCHAR(20)
                            CHECK (death_benefit_option IN
                                ('LUMPSUM','MONTHLY_INCOME','INCREASING')),
    critical_illness_cover  BOOLEAN         NOT NULL DEFAULT FALSE,
    accidental_death_cover  BOOLEAN         NOT NULL DEFAULT FALSE,
    waiver_of_premium       BOOLEAN         NOT NULL DEFAULT FALSE,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- =============================================================================
-- §7  INSURED MEMBERS & NOMINEES
-- =============================================================================

CREATE TABLE insured_members (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_id           VARCHAR(30)     NOT NULL REFERENCES policies(id) ON DELETE CASCADE,
    member_type         VARCHAR(20)     NOT NULL
                        CHECK (member_type IN
                            ('SELF','SPOUSE','CHILD','PARENT','PARENT_IN_LAW','SIBLING')),
    full_name           VARCHAR(150)    NOT NULL,
    date_of_birth       DATE            NOT NULL,
    gender              CHAR(1)         CHECK (gender IN ('M','F','O')),
    relation_to_proposer VARCHAR(30)    NOT NULL,
    pre_existing_disease TEXT,
    is_primary_insured  BOOLEAN         NOT NULL DEFAULT FALSE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_members_policy ON insured_members(policy_id);

CREATE TABLE il_nominees (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_id           VARCHAR(30)     NOT NULL REFERENCES policies(id) ON DELETE CASCADE,
    full_name           VARCHAR(150)    NOT NULL,
    date_of_birth       DATE,
    relation_to_insured VARCHAR(40)     NOT NULL,
    share_percent       NUMERIC(5,2)    NOT NULL
                        CHECK (share_percent > 0 AND share_percent <= 100),
    contact_phone       VARCHAR(20),
    is_minor            BOOLEAN         NOT NULL DEFAULT FALSE,
    appointee_name      VARCHAR(150),
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_nominees_policy ON il_nominees(policy_id);

-- =============================================================================
-- §8  CAMPAIGNS
-- 11 columns match Excel 🎯 Campaign sheet
-- =============================================================================

CREATE TABLE campaigns (
    -- PK: readable format — CAMP-DEC25-001 (matches Excel Campaign ID)
    id                  VARCHAR(30)     PRIMARY KEY,

    -- Excel col: "Campaign Name"
    name                VARCHAR(150)    NOT NULL,

    -- Excel col: "Product Line" — ALL
    product_line        VARCHAR(20)
                        CHECK (product_line IN
                            ('HEALTH','MOTOR','TRAVEL','HOME','COMMERCIAL','LIFE','ALL')),

    -- Excel col: "Target Segment" — ALL
    target_segment      VARCHAR(20)
                        CHECK (target_segment IN
                            ('PLATINUM','GOLD','SILVER','STANDARD','ALL')),

    -- Excel col: "Reminder Window" — 30DAY
    reminder_window     VARCHAR(10)     NOT NULL
                        CHECK (reminder_window IN ('30DAY','15DAY','7DAY','3DAY','ALL')),

    -- Excel cols: "Primary Channel", "Fallback 1", "Fallback 2"
    -- Denormalised for easy display — exact values: WHATSAPP, SMS, EMAIL
    primary_channel     VARCHAR(20)
                        CHECK (primary_channel IN ('WHATSAPP','SMS','EMAIL','VOICE')),
    fallback_channel_1  VARCHAR(20)
                        CHECK (fallback_channel_1 IN ('WHATSAPP','SMS','EMAIL','VOICE')),
    fallback_channel_2  VARCHAR(20)
                        CHECK (fallback_channel_2 IN ('WHATSAPP','SMS','EMAIL','VOICE')),

    -- Excel col: "Status" — RUNNING
    status              VARCHAR(20)     NOT NULL DEFAULT 'DRAFT'
                        CHECK (status IN ('DRAFT','RUNNING','PAUSED','COMPLETED','CANCELLED')),

    -- Excel cols: "Start Date", "End Date"
    scheduled_start     DATE,
    scheduled_end       DATE,

    description         TEXT,
    created_by          VARCHAR(60),
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE campaigns IS
    'PK: CAMP-DEC25-001 format. primary_channel + fallback_channel_1/2 match Excel directly.';

CREATE INDEX idx_campaigns_status ON campaigns(status);

-- =============================================================================
-- §9  RENEWAL TOKENS
-- 11 columns match Excel 🔑 Renewal Tokens sheet
-- =============================================================================

CREATE TABLE renewal_tokens (
    -- PK: TOK-7FC5D314 format — matches Excel "Token UUID" column
    id                  VARCHAR(30)     PRIMARY KEY,

    -- Excel col: "Policy UUID" — POL-GV-H001 etc.
    policy_id           VARCHAR(30)     NOT NULL REFERENCES policies(id) ON DELETE CASCADE,

    -- Excel col: "Customer" — display name (denorm)
    customer_name       VARCHAR(170),

    -- FK to campaigns
    campaign_id         VARCHAR(30)     REFERENCES campaigns(id),

    -- Excel col: "Channel" — WHATSAPP, EMAIL
    channel_id          SMALLINT        NOT NULL REFERENCES channels(id),

    -- Internal only — SHA-256 hash of the JWT; never exposed
    token_hash          VARCHAR(512)    NOT NULL UNIQUE,

    -- Excel col: "Short Code" — gv8k3m, au7x9n, kg2p5r
    short_code          VARCHAR(20)     NOT NULL UNIQUE,

    -- Excel col: "Short URL" — https://rnwq.in/gv8k3m
    short_url           TEXT            NOT NULL,

    -- Excel col: "Issued At" — 2026-03-17 etc.
    issued_at           DATE            NOT NULL DEFAULT CURRENT_DATE,

    -- Excel col: "Expires At" — 2026-04-01 etc.
    expires_at          DATE            NOT NULL,

    -- Excel col: "Is Used" — No for all 3
    is_used             BOOLEAN         NOT NULL DEFAULT FALSE,
    used_at             TIMESTAMPTZ,

    -- Excel col: "Is Invalidated" — No for all 3
    is_invalidated      BOOLEAN         NOT NULL DEFAULT FALSE,
    invalidated_at      TIMESTAMPTZ,
    invalidation_reason VARCHAR(100),

    -- Excel col: "Status" — ACTIVE / USED / INVALIDATED
    -- Derived: is_used=TRUE → USED, is_invalidated=TRUE → INVALIDATED, else ACTIVE
    -- Stored as computed-equivalent for query convenience
    token_status        VARCHAR(15)     NOT NULL DEFAULT 'ACTIVE'
                        CHECK (token_status IN ('ACTIVE','USED','INVALIDATED')),

    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE renewal_tokens IS
    'short_code/short_url match Excel. token_hash never exposed — internal JWT validation only.';

CREATE INDEX idx_tokens_policy   ON renewal_tokens(policy_id);
CREATE INDEX idx_tokens_code     ON renewal_tokens(short_code);
CREATE INDEX idx_tokens_active   ON renewal_tokens(is_used, is_invalidated, expires_at)
    WHERE is_used = FALSE AND is_invalidated = FALSE;

-- =============================================================================
-- §10  REMINDERS
-- 12 columns match Excel 🔔 Reminders sheet exactly
-- =============================================================================

CREATE TABLE reminders (
    -- PK: REM-321093EF format — matches Excel "Reminder UUID"
    id                  VARCHAR(30)     PRIMARY KEY,

    -- Excel col: "Campaign" — CAMP-DEC25-001
    campaign_id         VARCHAR(30)     REFERENCES campaigns(id),

    -- Excel col: "Policy UUID" — POL-GV-H001 etc.
    policy_id           VARCHAR(30)     NOT NULL REFERENCES policies(id) ON DELETE CASCADE,

    -- FK to customers
    customer_id         VARCHAR(30)     NOT NULL REFERENCES customers(id) ON DELETE CASCADE,

    -- Excel col: "Customer" — display name (denorm, avoids join in scheduler)
    customer_name       VARCHAR(170),

    -- FK to channels
    channel_id          SMALLINT        NOT NULL REFERENCES channels(id),

    -- FK to message templates
    template_id         INT             REFERENCES message_templates(id),

    -- Excel col: "Reminder Window" — 30DAY, 15DAY
    reminder_window     VARCHAR(10)     NOT NULL
                        CHECK (reminder_window IN ('30DAY','15DAY','7DAY','3DAY')),

    -- Excel col: "Attempt #" — 1
    attempt_number      SMALLINT        NOT NULL DEFAULT 1,

    -- Excel col: "Scheduled At" — 2026-03-07 10:45
    scheduled_at        TIMESTAMPTZ     NOT NULL,

    -- Excel col: "Sent At"
    sent_at             TIMESTAMPTZ,

    -- Excel col: "Delivery Status" — READ, DELIVERED, OPENED
    delivery_status     VARCHAR(20)     NOT NULL DEFAULT 'PENDING'
                        CHECK (delivery_status IN
                            ('PENDING','SENT','DELIVERED','READ',
                             'OPENED','CLICKED','NO_RESPONSE','FAILED','CANCELLED')),

    -- Excel col: "Link Clicked" — Yes/No
    link_clicked        BOOLEAN         NOT NULL DEFAULT FALSE,
    clicked_at          TIMESTAMPTZ,

    -- Excel col: "Renewed After Click" — No
    renewed_after_click BOOLEAN         NOT NULL DEFAULT FALSE,

    -- Self-referencing for fallback chains
    parent_reminder_id  VARCHAR(30)     REFERENCES reminders(id),
    fallback_triggered  BOOLEAN         NOT NULL DEFAULT FALSE,

    agent_notes         TEXT,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE reminders IS
    'PK: REM-XXXXXXXX format. delivery_status includes OPENED for email tracking.';

CREATE INDEX idx_reminders_policy     ON reminders(policy_id);
CREATE INDEX idx_reminders_customer   ON reminders(customer_id);
CREATE INDEX idx_reminders_campaign   ON reminders(campaign_id);
CREATE INDEX idx_reminders_status     ON reminders(delivery_status);
CREATE INDEX idx_reminders_scheduled  ON reminders(scheduled_at)
    WHERE delivery_status = 'PENDING';
CREATE INDEX idx_reminders_channel    ON reminders(channel_id, sent_at);

-- =============================================================================
-- §11  CHANNEL-SPECIFIC LOGS
-- =============================================================================

-- 11.1  WhatsApp Logs
-- 12 columns match Excel 💬 WhatsApp Logs sheet
CREATE TABLE whatsapp_logs (
    -- PK: WLOG-3E4F5CFF format — matches Excel "Log UUID"
    id                  VARCHAR(30)     PRIMARY KEY,

    -- Excel col: "Reminder UUID" — REM-B456BA43 etc.
    reminder_id         VARCHAR(30)     NOT NULL REFERENCES reminders(id) ON DELETE CASCADE,

    -- Excel col: "Customer" — display name
    customer_name       VARCHAR(170),

    -- Excel col: "WA Number" — +919893010159
    wa_number           VARCHAR(20)     NOT NULL,

    -- Excel col: "Meta Message ID" — wamid.HBgL938924CC (length 50 extended)
    meta_message_id     VARCHAR(50)     UNIQUE,

    -- Excel col: "Template Name" — il_health_expiry_hi_30d
    template_name       VARCHAR(100),

    -- Excel cols: "Sent At", "Delivered At", "Read At"
    sent_at             TIMESTAMPTZ,
    delivered_at        TIMESTAMPTZ,
    read_at             TIMESTAMPTZ,

    -- Excel col: "Delivery Status" — READ, DELIVERED
    delivery_status     VARCHAR(20)     NOT NULL DEFAULT 'SENT'
                        CHECK (delivery_status IN
                            ('SENT','DELIVERED','READ','FAILED')),

    -- Excel col: "Button Clicked" — "Renew Now" (string label, not boolean)
    button_label        VARCHAR(50),

    -- Excel col: "Reply Text" — "Bhai link bhejo abhi renew karta hoon"
    reply_text          TEXT,
    reply_received      BOOLEAN         NOT NULL DEFAULT FALSE,
    replied_at          TIMESTAMPTZ,

    error_code          VARCHAR(20),
    error_message       TEXT,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON COLUMN whatsapp_logs.button_label IS
    'String label of button pressed — e.g. "Renew Now". Matches Excel Button Clicked column.';
COMMENT ON COLUMN whatsapp_logs.meta_message_id IS
    'Extended to VARCHAR(50) — file shows wamid.HBgL938924CC format (24 chars).';

CREATE INDEX idx_wa_reminder ON whatsapp_logs(reminder_id);

-- 11.2  SMS Logs
-- 12 columns match Excel 📱 SMS Logs sheet
CREATE TABLE sms_logs (
    -- PK: SLOG-0ED0E029 format
    id                  VARCHAR(30)     PRIMARY KEY,

    -- Excel col: "Reminder UUID"
    reminder_id         VARCHAR(30)     NOT NULL REFERENCES reminders(id) ON DELETE CASCADE,

    -- Excel col: "Customer"
    customer_name       VARCHAR(170),

    -- Excel col: "Phone" — +919893010159
    phone_number        VARCHAR(20)     NOT NULL,

    -- Excel col: "Provider" — MSG91
    provider            VARCHAR(30)     NOT NULL,

    -- Excel col: "Provider Msg ID" — MSGFDB8B074
    provider_msg_id     VARCHAR(100)    UNIQUE,

    -- Excel col: "Sender ID" — ICICILOM
    sender_id           VARCHAR(20),

    -- Excel col: "DLT Template ID" — 1107165432987612
    dlt_template_id     VARCHAR(50),

    -- Excel cols: "Sent At", "Delivered At"
    sent_at             TIMESTAMPTZ,
    delivered_at        TIMESTAMPTZ,

    -- Excel col: "Delivery Status" — DELIVERED
    delivery_status     VARCHAR(20)     NOT NULL DEFAULT 'SENT'
                        CHECK (delivery_status IN
                            ('SENT','DELIVERED','FAILED','REJECTED')),

    -- Excel col: "Cost (₹)" — 0.12
    cost_inr            NUMERIC(6,4),

    error_code          VARCHAR(20),
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_sms_reminder ON sms_logs(reminder_id);
CREATE INDEX idx_sms_phone    ON sms_logs(phone_number);

-- 11.3  Email Logs
-- 12 columns match Excel 📧 Email Logs sheet
CREATE TABLE email_logs (
    -- PK: ELOG-E864FEC7 format
    id                  VARCHAR(30)     PRIMARY KEY,

    -- Excel col: "Reminder UUID"
    reminder_id         VARCHAR(30)     NOT NULL REFERENCES reminders(id) ON DELETE CASCADE,

    -- Excel col: "Customer"
    customer_name       VARCHAR(170),

    -- Excel col: "To Email" — ayushupadhyay373@gmail.com
    to_email            VARCHAR(150)    NOT NULL,

    -- Excel col: "From Email" — renewals@icicilombard.com
    from_email          VARCHAR(150)    NOT NULL,

    -- Excel col: "Subject" — long subjects, extended to VARCHAR(300)
    subject             VARCHAR(300)    NOT NULL,

    -- Excel cols: "Sent At", "Opened At", "Clicked At"
    sent_at             TIMESTAMPTZ,
    opened_at           TIMESTAMPTZ,
    clicked_at          TIMESTAMPTZ,

    -- Excel col: "Delivery Status" — CLICKED, OPENED
    delivery_status     VARCHAR(20)     NOT NULL DEFAULT 'SENT'
                        CHECK (delivery_status IN
                            ('SENT','DELIVERED','OPENED','CLICKED',
                             'BOUNCED','SPAM','FAILED')),

    bounce_type         VARCHAR(10)     CHECK (bounce_type IN ('HARD','SOFT')),
    is_unsubscribed     BOOLEAN         NOT NULL DEFAULT FALSE,
    unsubscribed_at     TIMESTAMPTZ,

    -- Excel cols: "Open Count" (2,1), "Click Count" (1,0)
    open_count          SMALLINT        NOT NULL DEFAULT 0,
    click_count         SMALLINT        NOT NULL DEFAULT 0,

    provider            VARCHAR(30),
    provider_msg_id     VARCHAR(150)    UNIQUE,
    error_code          VARCHAR(20),
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON COLUMN email_logs.subject IS
    'Extended to VARCHAR(300) — file subject: "Action Required: Your Motor Insurance Expires in 22 Days"';

CREATE INDEX idx_email_reminder ON email_logs(reminder_id);

-- 11.4  Voice Logs (no records in file but kept for fallback support)
CREATE TABLE voice_logs (
    id                  VARCHAR(30)     PRIMARY KEY,
    reminder_id         VARCHAR(30)     NOT NULL REFERENCES reminders(id) ON DELETE CASCADE,
    phone_number        VARCHAR(20)     NOT NULL,
    initiated_at        TIMESTAMPTZ     NOT NULL,
    answered_at         TIMESTAMPTZ,
    ended_at            TIMESTAMPTZ,
    duration_seconds    INT,
    call_outcome        VARCHAR(30)     NOT NULL DEFAULT 'PENDING'
                        CHECK (call_outcome IN
                            ('PENDING','ANSWERED_INTERESTED','ANSWERED_NOT_INTERESTED',
                             'NO_ANSWER','VOICEMAIL','CALL_FAILED','ANSWERED_CALLBACK')),
    ivr_key_pressed     VARCHAR(5),
    is_interested       BOOLEAN,
    callback_requested  BOOLEAN         NOT NULL DEFAULT FALSE,
    callback_time       TIMESTAMPTZ,
    retry_number        SMALLINT        NOT NULL DEFAULT 1,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_voice_reminder  ON voice_logs(reminder_id);
CREATE INDEX idx_voice_callback  ON voice_logs(callback_requested, callback_time)
    WHERE callback_requested = TRUE;

-- =============================================================================
-- §12  CLAIMS
-- =============================================================================

CREATE TABLE il_claims (
    id                      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_id               VARCHAR(30)     NOT NULL REFERENCES policies(id),
    customer_id             VARCHAR(30)     NOT NULL REFERENCES customers(id),
    claim_number            VARCHAR(30)     NOT NULL UNIQUE,
    claim_type              VARCHAR(20)     NOT NULL
                            CHECK (claim_type IN
                                ('CASHLESS','REIMBURSEMENT','THIRD_PARTY')),
    date_of_loss            DATE            NOT NULL,
    date_of_intimation      DATE            NOT NULL,
    claimed_amount_inr      NUMERIC(14,2)   NOT NULL,
    approved_amount_inr     NUMERIC(14,2),
    settled_amount_inr      NUMERIC(14,2),
    claim_status            VARCHAR(20)     NOT NULL DEFAULT 'INTIMATED'
                            CHECK (claim_status IN
                                ('INTIMATED','UNDER_REVIEW','APPROVED',
                                 'SETTLED','REJECTED','WITHDRAWN')),
    rejection_reason        TEXT,
    settled_at              TIMESTAMPTZ,
    tpa_claim_id            VARCHAR(30),
    hospital_name           VARCHAR(200),
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_claims_policy   ON il_claims(policy_id);
CREATE INDEX idx_claims_customer ON il_claims(customer_id);
CREATE INDEX idx_claims_status   ON il_claims(claim_status);

-- =============================================================================
-- §13  PAYMENTS
-- 16 columns match Excel 💳 Payments sheet exactly
-- =============================================================================

CREATE TABLE payments (
    -- PK: PAY-C56650CA format — matches Excel "Payment UUID"
    id                  VARCHAR(30)     PRIMARY KEY,

    -- Excel col: "Policy UUID"
    policy_id           VARCHAR(30)     NOT NULL REFERENCES policies(id) ON DELETE CASCADE,

    -- Excel col: "Customer" — display name (denorm)
    customer_name       VARCHAR(170),

    -- FK
    customer_id         VARCHAR(30)     NOT NULL REFERENCES customers(id),

    -- Excel col: "Campaign" — CAMP-DEC25-001
    campaign_id         VARCHAR(30)     REFERENCES campaigns(id),

    -- Excel col: "Channel Source" — WHATSAPP
    channel_source_id   SMALLINT        REFERENCES channels(id),

    -- FK to renewal token
    token_id            VARCHAR(30)     REFERENCES renewal_tokens(id),

    -- Excel col: "Gateway" — RAZORPAY
    gateway             VARCHAR(30)     NOT NULL,

    -- Excel col: "Gateway Order ID" — order_E81D8911CCCF8949 (length 50)
    gateway_order_id    VARCHAR(50)     UNIQUE,

    -- Excel col: "Gateway Txn ID" — pay_8232C42AAA6B14FD (length 50)
    gateway_txn_id      VARCHAR(50)     UNIQUE,

    -- Excel col: "Net Premium (₹)" — 13490
    amount_inr          NUMERIC(12,2)   NOT NULL CHECK (amount_inr > 0),

    -- Excel col: "GST (₹)" — 2428.20
    gst_inr             NUMERIC(12,2)   NOT NULL DEFAULT 0,

    -- Excel col: "Total Paid (₹)" — 15918.20
    total_inr           NUMERIC(12,2)   NOT NULL CHECK (total_inr > 0),

    -- Excel col: "Payment Method" — UPI
    payment_method      VARCHAR(30),

    -- Excel col: "Status" — COMPLETED
    status              VARCHAR(20)     NOT NULL DEFAULT 'INITIATED'
                        CHECK (status IN
                            ('INITIATED','COMPLETED','FAILED','REFUNDED','PENDING')),

    initiated_at        TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    -- Excel col: "Completed At" — 2026-03-18 (DATE stored)
    completed_at        TIMESTAMPTZ,

    -- Excel col: "Policy Renewed From" — 2026-03-30
    policy_renewed_from DATE,

    -- Excel col: "Policy Renewed To" — 2027-03-30
    policy_renewed_to   DATE,

    failure_reason      VARCHAR(200),
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE payments IS
    'Gagan Verma renewed via WhatsApp (CAMP-DEC25-001). gateway_order_id/txn_id extended to VARCHAR(50).';

CREATE INDEX idx_payments_policy    ON payments(policy_id);
CREATE INDEX idx_payments_customer  ON payments(customer_id);
CREATE INDEX idx_payments_status    ON payments(status);
CREATE INDEX idx_payments_completed ON payments(completed_at)
    WHERE status = 'COMPLETED';
CREATE INDEX idx_payments_campaign  ON payments(campaign_id)
    WHERE campaign_id IS NOT NULL;

-- =============================================================================
-- §14  ANALYTICS  (pre-aggregated)
-- =============================================================================

CREATE TABLE analytics_daily (
    id                      BIGSERIAL       PRIMARY KEY,
    snapshot_date           DATE            NOT NULL,
    product_line            VARCHAR(20)     NOT NULL DEFAULT 'ALL',
    policies_scanned        INT             NOT NULL DEFAULT 0,
    newly_flagged           INT             NOT NULL DEFAULT 0,
    reminders_sent          INT             NOT NULL DEFAULT 0,
    wa_sent                 INT             NOT NULL DEFAULT 0,
    sms_sent                INT             NOT NULL DEFAULT 0,
    email_sent              INT             NOT NULL DEFAULT 0,
    voice_calls             INT             NOT NULL DEFAULT 0,
    total_opened            INT             NOT NULL DEFAULT 0,
    total_clicked           INT             NOT NULL DEFAULT 0,
    renewals_completed      INT             NOT NULL DEFAULT 0,
    revenue_inr             NUMERIC(16,2)   NOT NULL DEFAULT 0,
    opt_outs                INT             NOT NULL DEFAULT 0,
    renewal_rate_pct        NUMERIC(5,2)    GENERATED ALWAYS AS (
        CASE WHEN reminders_sent > 0
             THEN ROUND(renewals_completed::NUMERIC / reminders_sent * 100, 2)
             ELSE 0 END
    ) STORED,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    UNIQUE (snapshot_date, product_line)
);

CREATE TABLE analytics_branch_daily (
    id                  BIGSERIAL       PRIMARY KEY,
    branch_code         VARCHAR(20)     NOT NULL REFERENCES il_branches(branch_code),
    snapshot_date       DATE            NOT NULL,
    reminders_sent      INT             NOT NULL DEFAULT 0,
    renewals_completed  INT             NOT NULL DEFAULT 0,
    revenue_inr         NUMERIC(14,2)   NOT NULL DEFAULT 0,
    renewal_rate_pct    NUMERIC(5,2)    GENERATED ALWAYS AS (
        CASE WHEN reminders_sent > 0
             THEN ROUND(renewals_completed::NUMERIC / reminders_sent * 100, 2)
             ELSE 0 END
    ) STORED,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    UNIQUE (branch_code, snapshot_date)
);

CREATE TABLE analytics_agent_daily (
    id                  BIGSERIAL       PRIMARY KEY,
    agent_code          VARCHAR(30)     NOT NULL REFERENCES il_agents(agent_code),
    snapshot_date       DATE            NOT NULL,
    policies_expiring   INT             NOT NULL DEFAULT 0,
    reminders_sent      INT             NOT NULL DEFAULT 0,
    renewals_completed  INT             NOT NULL DEFAULT 0,
    revenue_inr         NUMERIC(14,2)   NOT NULL DEFAULT 0,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    UNIQUE (agent_code, snapshot_date)
);

CREATE TABLE analytics_channel_daily (
    id              BIGSERIAL   PRIMARY KEY,
    channel_id      SMALLINT    NOT NULL REFERENCES channels(id),
    snapshot_date   DATE        NOT NULL,
    sent            INT         NOT NULL DEFAULT 0,
    delivered       INT         NOT NULL DEFAULT 0,
    opened          INT         NOT NULL DEFAULT 0,
    clicked         INT         NOT NULL DEFAULT 0,
    renewed         INT         NOT NULL DEFAULT 0,
    failed          INT         NOT NULL DEFAULT 0,
    opt_outs        INT         NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (channel_id, snapshot_date)
);

-- =============================================================================
-- §15  AUDIT LOG
-- =============================================================================

CREATE TABLE audit_logs (
    id          BIGSERIAL   PRIMARY KEY,
    entity_type VARCHAR(50) NOT NULL,
    entity_id   TEXT        NOT NULL,
    action      VARCHAR(30) NOT NULL
                CHECK (action IN
                    ('INSERT','UPDATE','DELETE','STATUS_CHANGE',
                     'OPT_OUT','LOGIN','PAYMENT','TOKEN_USED')),
    old_values  JSONB,
    new_values  JSONB,
    performed_by VARCHAR(60),
    ip_address  INET,
    user_agent  TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX idx_audit_entity ON audit_logs(entity_type, entity_id);
CREATE INDEX idx_audit_date   ON audit_logs(created_at DESC);

-- =============================================================================
-- §16  AUTO updated_at TRIGGER
-- =============================================================================

CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN NEW.updated_at = NOW(); RETURN NEW; END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE t TEXT;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'il_products','channels','languages','message_templates',
        'il_zones','il_regions','il_branches',
        'il_territory_managers','il_sales_managers',
        'il_relationship_managers','il_agents',
        'customers','policies',
        'il_health_details','il_motor_details',
        'il_travel_details','il_home_details',
        'il_commercial_details','il_life_details',
        'insured_members','il_nominees',
        'campaigns','renewal_tokens',
        'reminders','whatsapp_logs','sms_logs','email_logs','voice_logs',
        'il_claims','payments',
        'analytics_daily','analytics_branch_daily','analytics_channel_daily'
    ]
    LOOP
        EXECUTE format(
            'CREATE TRIGGER trg_%s_updated_at
             BEFORE UPDATE ON %s
             FOR EACH ROW EXECUTE FUNCTION trigger_set_updated_at();',
            t, t
        );
    END LOOP;
END;
$$;

-- =============================================================================
-- §17  SEED DATA  (exact values from Excel file)
-- =============================================================================

-- Channels
INSERT INTO channels (code, label, default_wait_hrs, daily_limit) VALUES
    ('WHATSAPP', 'WhatsApp',  4,  5000),
    ('SMS',      'SMS',       8,  10000),
    ('EMAIL',    'Email',     24, 50000),
    ('VOICE',    'Voice Call',48, 1000);

-- Languages (file uses hi, en)
INSERT INTO languages (code, label) VALUES
    ('en', 'English'), ('hi', 'Hindi'), ('mr', 'Marathi'),
    ('ta', 'Tamil'),   ('te', 'Telugu'), ('kn', 'Kannada'),
    ('bn', 'Bengali'), ('gu', 'Gujarati'), ('pa', 'Punjabi');

-- IL Products (product codes from Excel)
INSERT INTO il_products (product_code, product_name, product_line, policy_prefix) VALUES
    ('IHEALTH_IND',  'iHealth Individual',       'HEALTH', '4128'),
    ('IHEALTH_FAM',  'iHealth Family Floater',    'HEALTH', '4128'),
    ('HLTH_ADV',     'Health Advantage',          'HEALTH', '4128'),
    ('MOTOR_PC',     'Private Car Package',       'MOTOR',  '3001'),
    ('MOTOR_TW',     'Two Wheeler Package',       'MOTOR',  '3002'),
    ('TRAVEL_ST',    'Travel Single Trip',        'TRAVEL', '4003'),
    ('TRAVEL_MT',    'Travel Multi Trip Annual',  'TRAVEL', '4003'),
    ('HOME_SHIELD',  'Home Shield',               'HOME',   '4150'),
    ('BHARAT_GRIHA', 'Bharat Griha Raksha',       'HOME',   '4150'),
    ('SME_SHOP',     'Shopkeeper Policy',         'COMMERCIAL','5001'),
    ('IL_TERM',      'iProtect Smart Term Plan',  'LIFE',   '6001');

-- Message Templates (template_code values from Excel Template Name column)
INSERT INTO message_templates
    (channel_id, language_id, product_line, reminder_window,
     template_code, body_text, dlt_template_id, is_approved)
VALUES
    -- WhatsApp Hindi Health 30-day
    (1, 2, 'HEALTH', '30DAY',
     'il_health_expiry_hi_30d',
     'Namaste {name}! Aapki ICICI Lombard Health Policy {policy_num} 30 din mein expire ho rahi hai. Abhi renew karein: {link}',
     NULL, TRUE),
    -- WhatsApp Hindi Health 15-day urgent
    (1, 2, 'HEALTH', '15DAY',
     'il_health_urgent_hi_15d',
     'URGENT: {name} ji, aapki Health Policy sirf 15 din mein expire hogi! Turant renew karein: {link}',
     NULL, TRUE),
    -- SMS English Motor 15-day
    (2, 1, 'MOTOR', '15DAY',
     'il_motor_renewal_en_15d',
     'Dear {name}, Your ICICI Lombard Motor Policy {policy_num} expires in 15 days. Renew: {link}',
     '1107165432987612', TRUE),
    -- SMS English Health 15-day
    (2, 1, 'HEALTH', '15DAY',
     'il_health_renewal_en_15d',
     'Dear {name}, Your ICICI Lombard Health Policy {policy_num} expires in 15 days. Renew: {link}',
     '1107165432987613', TRUE),
    -- Email English Motor 30-day
    (3, 1, 'MOTOR', '30DAY',
     'il_motor_renewal_en_30d',
     'Dear {name},\n\nYour ICICI Lombard Motor Insurance Policy {policy_num} is due for renewal in 30 days.\n\nClick here to renew: {link}\n\nRegards,\nICICI Lombard',
     NULL, TRUE);

-- Zones
INSERT INTO il_zones (zone_code, zone_name, hq_city) VALUES
    ('NORTH',   'North Zone',   'New Delhi'),
    ('SOUTH',   'South Zone',   'Chennai'),
    ('EAST',    'East Zone',    'Kolkata'),
    ('WEST',    'West Zone',    'Mumbai'),
    ('CENTRAL', 'Central Zone', 'Bhopal');

-- Regions
INSERT INTO il_regions (zone_id, region_code, region_name, hq_city) VALUES
    (5, 'REG_IND', 'Indore Region',    'Indore'),   -- CENTRAL
    (3, 'REG_BHU', 'Bhubaneswar Region','Bhubaneswar'), -- EAST
    (5, 'REG_NAG', 'Nagpur Region',    'Nagpur');   -- CENTRAL

-- Branches (exact codes from Excel: BR_IND001, BR_BHU001, BR_NAG001)
INSERT INTO il_branches (region_id, branch_code, branch_name, city, state, pincode) VALUES
    (1, 'BR_IND001', 'Indore MG Road Branch',        'Indore',       'Madhya Pradesh', '452001'),
    (2, 'BR_BHU001', 'Bhubaneswar Unit 9 Branch',    'Bhubaneswar',  'Odisha',         '751022'),
    (3, 'BR_NAG001', 'Nagpur Wardha Road Branch',    'Nagpur',       'Maharashtra',    '440010');

-- Customers (exact data from Excel — 3 real customers)
INSERT INTO customers (
    id, il_customer_id, first_name, last_name,
    date_of_birth, gender, pan_number, aadhaar_last4,
    email, phone, whatsapp_number,
    city, state, pincode,
    preferred_channel_id, preferred_language_id,
    customer_segment, kyc_status, is_nri, is_opted_out, created_at
) VALUES
    ('CUST-GV-001', 'IL78430159', 'Gagan',  'Verma',
     '1990-06-15', 'M', 'ABJPV4821K', '7823',
     'gaganverma@gmail.com', '+919893010159', '+919893010159',
     'Indore', 'Madhya Pradesh', '452001',
     1, 2,  -- WHATSAPP, hi
     'GOLD', 'VERIFIED', FALSE, FALSE, '2021-03-12'),

    ('CUST-AU-002', 'IL92745600', 'Ayush',  'Upadhyay',
     '1995-11-28', 'M', 'CMNPU3742H', '4561',
     'ayushupadhyay373@gmail.com', '+917869745600', '+917869745600',
     'Bhopal', 'Madhya Pradesh', '462001',
     3, 1,  -- EMAIL, en
     'SILVER', 'VERIFIED', FALSE, FALSE, '2022-08-05'),

    ('CUST-KG-003', 'IL62613248', 'Gourav', 'K.',
     '1993-04-09', 'M', 'FKRPG5194M', '3197',
     'k.gourav254@gmail.com', '+916261397248', '+916261397248',
     'Raipur', 'Chhattisgarh', '492001',
     1, 2,  -- WHATSAPP, hi
     'STANDARD', 'VERIFIED', FALSE, FALSE, '2023-01-20');

-- Policies (exact values from Excel — all 3 EXPIRING)
INSERT INTO policies (
    id, il_policy_number, customer_id, product_code, product_line,
    branch_code, agent_code, rm_code,
    risk_start_date, risk_end_date,
    sum_insured, net_premium, gst_rate,
    payment_mode, policy_status,
    renewal_count, is_first_policy, issue_date
) VALUES
    ('POL-GV-H001', '4128/2024/83040159', 'CUST-GV-001', 'IHEALTH_FAM', 'HEALTH',
     'BR_IND001', 'AG007', 'RM004',
     '2024-12-20', '2026-03-30',
     500000, 13490, 18.00,
     'ANNUAL', 'EXPIRING',
     3, FALSE, '2024-12-15'),

    ('POL-AU-M001', '3001/2024/76745600', 'CUST-AU-002', 'MOTOR_PC', 'MOTOR',
     'BR_BHU001', 'AG015', 'RM002',
     '2024-11-10', '2026-04-10',
     720000, 16650, 18.00,
     'ANNUAL', 'EXPIRING',
     1, FALSE, '2024-11-05'),

    ('POL-KG-H001', '4128/2025/61397248', 'CUST-KG-003', 'IHEALTH_IND', 'HEALTH',
     'BR_NAG001', 'AG023', 'RM005',
     '2025-01-20', '2026-04-15',
     300000, 8455, 18.00,
     'ANNUAL', 'EXPIRING',
     0, TRUE, '2025-01-15');

-- Health Details (exact from Excel)
INSERT INTO il_health_details (
    policy_id, customer_name, plan_variant, sum_insured_slab, members_insured,
    copay_percent, room_rent_limit_inr, pre_existing_wait_days,
    maternity_covered, ncb_pct, cumulative_bonus_pct, deductible_amount,
    tpa_id, network_hospital_count, covid_covered
) VALUES
    ('POL-GV-H001', 'Gagan Verma',
     'FAMILY_FLOATER', '5L', 3,
     10, 5000, 1095,
     TRUE, 15, 10, 5000,
     'TPA002', 9500, TRUE),

    ('POL-KG-H001', 'Gourav K.',
     'INDIVIDUAL', '3L', 1,
     0, 3500, 730,
     FALSE, 0, 0, 0,
     'TPA001', 8200, TRUE);

-- Motor Details (exact from Excel — Hyundai Creta SX(O))
INSERT INTO il_motor_details (
    policy_id, customer_name, vehicle_type, registration_number,
    make, model, variant, manufacture_year, fuel_type, engine_cc, rto_code,
    policy_type, idv_amount, ncb_percent, ncb_cert_no,
    pa_cover_owner, nil_depreciation, rsa_cover
) VALUES
    ('POL-AU-M001', 'Ayush Upadhyay',
     'PRIVATE_CAR', 'MP09CD4521',
     'Hyundai', 'Creta', 'SX(O)', 2022, 'PETROL', 1497, 'MP09',
     'COMPREHENSIVE', 720000, 20, 'NCB203412',
     TRUE, TRUE, TRUE);

-- Campaign (exact from Excel)
INSERT INTO campaigns (
    id, name, product_line, target_segment, reminder_window,
    primary_channel, fallback_channel_1, fallback_channel_2,
    status, scheduled_start, scheduled_end
) VALUES
    ('CAMP-DEC25-001',
     'December 2025 Expiry Renewal Drive',
     'ALL', 'ALL', '30DAY',
     'WHATSAPP', 'SMS', 'EMAIL',
     'RUNNING', '2025-12-01', '2025-12-31');

-- Renewal Tokens (exact from Excel)
INSERT INTO renewal_tokens (
    id, policy_id, customer_name, campaign_id, channel_id,
    token_hash, short_code, short_url,
    issued_at, expires_at, is_used, is_invalidated, token_status
) VALUES
    ('TOK-7FC5D314', 'POL-GV-H001', 'Gagan Verma',  'CAMP-DEC25-001', 1,
     encode(sha256('jwt_gagan_verma_token_secret'), 'hex'),
     'gv8k3m', 'https://rnwq.in/gv8k3m',
     '2026-03-17', '2026-04-01', FALSE, FALSE, 'ACTIVE'),

    ('TOK-EA743CAA', 'POL-AU-M001', 'Ayush Upadhyay', 'CAMP-DEC25-001', 3,
     encode(sha256('jwt_ayush_upadhyay_token_secret'), 'hex'),
     'au7x9n', 'https://rnwq.in/au7x9n',
     '2026-03-18', '2026-04-11', FALSE, FALSE, 'ACTIVE'),

    ('TOK-49D5AD66', 'POL-KG-H001', 'Gourav K.',    'CAMP-DEC25-001', 1,
     encode(sha256('jwt_gourav_k_token_secret'), 'hex'),
     'kg2p5r', 'https://rnwq.in/kg2p5r',
     '2026-03-19', '2026-04-16', FALSE, FALSE, 'ACTIVE');

-- Reminders (exact UUIDs and data from Excel — 9 events)
INSERT INTO reminders (
    id, campaign_id, policy_id, customer_id, customer_name,
    channel_id, reminder_window, attempt_number,
    scheduled_at, sent_at, delivery_status,
    link_clicked, renewed_after_click
) VALUES
    ('REM-321093EF','CAMP-DEC25-001','POL-GV-H001','CUST-GV-001','Gagan Verma',
     1,'30DAY',1, '2026-03-07 10:45','2026-03-07 10:45','READ', FALSE,FALSE),

    ('REM-B936CCE5','CAMP-DEC25-001','POL-GV-H001','CUST-GV-001','Gagan Verma',
     1,'15DAY',1, '2026-03-17 10:45','2026-03-17 10:45','READ', TRUE, FALSE),

    ('REM-0297DED6','CAMP-DEC25-001','POL-GV-H001','CUST-GV-001','Gagan Verma',
     2,'15DAY',1, '2026-03-17 10:45','2026-03-17 10:45','DELIVERED',FALSE,FALSE),

    ('REM-69081190','CAMP-DEC25-001','POL-AU-M001','CUST-AU-002','Ayush Upadhyay',
     3,'30DAY',1, '2026-03-11 10:45','2026-03-11 10:45','OPENED', FALSE,FALSE),

    ('REM-0791C6A9','CAMP-DEC25-001','POL-AU-M001','CUST-AU-002','Ayush Upadhyay',
     1,'15DAY',1, '2026-03-18 10:45','2026-03-18 10:45','READ', FALSE,FALSE),

    ('REM-AU-SMS01','CAMP-DEC25-001','POL-AU-M001','CUST-AU-002','Ayush Upadhyay',
     2,'15DAY',1, '2026-03-18 10:45','2026-03-18 10:45','DELIVERED',FALSE,FALSE),

    ('REM-KG-WA001','CAMP-DEC25-001','POL-KG-H001','CUST-KG-003','Gourav K.',
     1,'30DAY',1, '2026-03-19 10:00','2026-03-19 10:00','DELIVERED',FALSE,FALSE),

    ('REM-KG-SMS01','CAMP-DEC25-001','POL-KG-H001','CUST-KG-003','Gourav K.',
     2,'30DAY',1, '2026-03-19 10:00','2026-03-19 10:00','DELIVERED',FALSE,FALSE),

    ('REM-KG-EML01','CAMP-DEC25-001','POL-KG-H001','CUST-KG-003','Gourav K.',
     3,'15DAY',1, '2026-03-20 10:00', NULL,'PENDING', FALSE,FALSE);

-- WhatsApp Logs (exact from Excel)
INSERT INTO whatsapp_logs (
    id, reminder_id, customer_name, wa_number, meta_message_id,
    template_name, sent_at, delivered_at, read_at,
    delivery_status, button_label, reply_text, reply_received
) VALUES
    ('WLOG-3E4F5CFF','REM-B936CCE5','Gagan Verma','+919893010159',
     'wamid.HBgL938924CC','il_health_expiry_hi_30d',
     '2026-03-17 10:14','2026-03-17 10:15','2026-03-17 11:03',
     'READ','Renew Now','Bhai link bhejo abhi renew karta hoon',TRUE),

    ('WLOG-8F935128','REM-B936CCE5','Gagan Verma','+919893010159',
     'wamid.HBgLB0312A2D','il_health_urgent_hi_15d',
     '2026-03-18 09:30','2026-03-18 09:31','2026-03-18 09:45',
     'READ', NULL,'Renewed kar diya online',TRUE),

    ('WLOG-1E352292','REM-KG-WA001','Gourav K.','+916261397248',
     'wamid.HBgLD88375BE','il_health_expiry_hi_30d',
     '2026-03-19 10:00','2026-03-19 10:01', NULL,
     'DELIVERED', NULL, NULL, FALSE);

-- SMS Logs (exact from Excel)
INSERT INTO sms_logs (
    id, reminder_id, customer_name, phone_number, provider,
    provider_msg_id, sender_id, dlt_template_id,
    sent_at, delivered_at, delivery_status, cost_inr
) VALUES
    ('SLOG-0ED0E029','REM-0297DED6','Gagan Verma','+919893010159',
     'MSG91','MSGFDB8B074','ICICILOM','1107165432987612',
     '2026-03-17 10:14','2026-03-17 10:16','DELIVERED',0.12),

    ('SLOG-CDBF6E6B','REM-AU-SMS01','Ayush Upadhyay','+917869745600',
     'MSG91','MSG33AE56A7','ICICILOM','1107165432987613',
     '2026-03-18 09:30','2026-03-18 09:32','DELIVERED',0.12);

-- Email Logs (exact from Excel)
INSERT INTO email_logs (
    id, reminder_id, customer_name, to_email, from_email, subject,
    sent_at, opened_at, clicked_at, delivery_status, open_count, click_count
) VALUES
    ('ELOG-E864FEC7','REM-69081190','Ayush Upadhyay',
     'ayushupadhyay373@gmail.com','renewals@icicilombard.com',
     'Action Required: Your Motor Insurance Expires in 22 Days — Renew Now',
     '2026-03-18 08:00','2026-03-18 09:17','2026-03-18 09:19',
     'CLICKED',2,1),

    ('ELOG-3B75DCE3','REM-0791C6A9','Ayush Upadhyay',
     'ayushupadhyay373@gmail.com','renewals@icicilombard.com',
     'Your Renewal Quote is Ready — Hyundai Creta Comprehensive ₹19,647',
     '2026-03-19 08:00','2026-03-19 10:44', NULL,
     'OPENED',1,0);

-- Payment (exact from Excel — Gagan Verma paid via UPI)
INSERT INTO payments (
    id, policy_id, customer_name, customer_id,
    campaign_id, channel_source_id, token_id,
    gateway, gateway_order_id, gateway_txn_id,
    amount_inr, gst_inr, total_inr,
    payment_method, status, completed_at,
    policy_renewed_from, policy_renewed_to
) VALUES
    ('PAY-C56650CA', 'POL-GV-H001', 'Gagan Verma', 'CUST-GV-001',
     'CAMP-DEC25-001', 1, 'TOK-7FC5D314',
     'RAZORPAY', 'order_E81D8911CCCF8949', 'pay_8232C42AAA6B14FD',
     13490, 2428.20, 15918.20,
     'UPI', 'COMPLETED', '2026-03-18 00:00',
     '2026-03-30', '2027-03-30');

-- Update Gagan's policy status to RENEWED after payment
UPDATE policies
SET    policy_status   = 'RENEWED',
       last_renewed_at = '2026-03-18 00:00',
       renewal_count   = renewal_count + 1,
       updated_at      = NOW()
WHERE  id = 'POL-GV-H001';

-- =============================================================================
-- END OF SCHEMA  v3.0
-- =============================================================================
