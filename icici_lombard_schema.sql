-- =============================================================================
--  RenewIQ — ICICI Lombard Insurance
--  Single-Tenant Database Schema (PostgreSQL · 3NF)
--  Version : 2.0.0  |  Single Company: ICICI Lombard General Insurance
--  Created : 2025-12-15
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";   -- trigram index for name search

-- =============================================================================
-- SECTION 1 : REFERENCE / LOOKUP TABLES
-- =============================================================================

-- 1.1  IL Product Catalogue (ICICI Lombard specific products)
CREATE TABLE il_products (
    id                  SMALLSERIAL     PRIMARY KEY,
    product_code        VARCHAR(30)     NOT NULL UNIQUE,
    product_name        VARCHAR(150)    NOT NULL,
    product_line        VARCHAR(20)     NOT NULL
                        CHECK (product_line IN
                            ('HEALTH','MOTOR','TRAVEL','HOME','COMMERCIAL','LIFE')),
    policy_prefix       VARCHAR(10)     NOT NULL,            -- e.g. 'IL', '4128'
    sub_type            VARCHAR(50),                         -- e.g. 'PRIVATE_CAR', 'TWO_WHEELER'
    min_tenure_days     SMALLINT        NOT NULL DEFAULT 365,
    max_tenure_days     SMALLINT        NOT NULL DEFAULT 365,
    gst_rate            NUMERIC(5,2)    NOT NULL DEFAULT 18.00,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    launch_date         DATE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_products IS
    'ICICI Lombard official product catalogue — Health, Motor, Travel, Home, Commercial, Life';

-- 1.2  Channels
CREATE TABLE channels (
    id                  SMALLSERIAL     PRIMARY KEY,
    code                VARCHAR(20)     NOT NULL UNIQUE,     -- WHATSAPP, SMS, EMAIL, VOICE
    label               VARCHAR(50)     NOT NULL,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    default_wait_hrs    SMALLINT        NOT NULL DEFAULT 24,
    daily_limit         INT             NOT NULL DEFAULT 10000,
    rate_limit_per_sec  SMALLINT        NOT NULL DEFAULT 100,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

-- 1.3  Languages
CREATE TABLE languages (
    id                  SMALLSERIAL     PRIMARY KEY,
    code                VARCHAR(10)     NOT NULL UNIQUE,
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
    template_code       VARCHAR(80)     NOT NULL UNIQUE,
    subject             VARCHAR(250),                        -- email only
    body_text           TEXT            NOT NULL,
    dlt_template_id     VARCHAR(50),                        -- TRAI DLT (SMS only)
    meta_template_name  VARCHAR(100),                       -- WhatsApp HSM name
    is_approved         BOOLEAN         NOT NULL DEFAULT FALSE,
    version             SMALLINT        NOT NULL DEFAULT 1,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    UNIQUE (channel_id, language_id, product_line, reminder_window, version)
);

CREATE INDEX idx_templates_channel_window
    ON message_templates(channel_id, reminder_window, product_line);

-- =============================================================================
-- SECTION 2 : IL GEOGRAPHY & AGENT HIERARCHY
-- =============================================================================

-- 2.1  Zones (Top level: North / South / East / West / Central)
CREATE TABLE il_zones (
    id                  SMALLSERIAL     PRIMARY KEY,
    zone_code           VARCHAR(10)     NOT NULL UNIQUE,     -- NORTH, SOUTH, EAST, WEST, CENTRAL
    zone_name           VARCHAR(60)     NOT NULL,
    hq_city             VARCHAR(80),
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_zones IS 'ICICI Lombard zone hierarchy — top level geography';

-- 2.2  Regions (Under each zone: e.g. Mumbai, Delhi NCR, Bengaluru)
CREATE TABLE il_regions (
    id                  SMALLSERIAL     PRIMARY KEY,
    zone_id             SMALLINT        NOT NULL REFERENCES il_zones(id),
    region_code         VARCHAR(15)     NOT NULL UNIQUE,
    region_name         VARCHAR(80)     NOT NULL,
    hq_city             VARCHAR(80),
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_regions IS 'IL regions within each zone';

CREATE INDEX idx_regions_zone ON il_regions(zone_id);

-- 2.3  Branches (Under each region)
CREATE TABLE il_branches (
    id                  SERIAL          PRIMARY KEY,
    region_id           SMALLINT        NOT NULL REFERENCES il_regions(id),
    branch_code         VARCHAR(20)     NOT NULL UNIQUE,     -- IL internal branch code
    branch_name         VARCHAR(150)    NOT NULL,
    city                VARCHAR(80)     NOT NULL,
    state               VARCHAR(80)     NOT NULL,
    pincode             VARCHAR(10),
    address             TEXT,
    phone               VARCHAR(20),
    email               VARCHAR(150),
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_branches IS 'IL branch offices under each region';

CREATE INDEX idx_branches_region ON il_branches(region_id);

-- 2.4  Territory Managers (TM — top of sales hierarchy)
CREATE TABLE il_territory_managers (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    branch_id           INT             NOT NULL REFERENCES il_branches(id),
    employee_code       VARCHAR(20)     NOT NULL UNIQUE,
    full_name           VARCHAR(150)    NOT NULL,
    email               VARCHAR(150)    NOT NULL UNIQUE,
    phone               VARCHAR(20),
    monthly_target_inr  NUMERIC(14,2),
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    joined_on           DATE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_territory_managers IS 'TM — top of the IL sales agent hierarchy';

-- 2.5  Sales Managers (SM — under TM)
CREATE TABLE il_sales_managers (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    tm_id               UUID            NOT NULL REFERENCES il_territory_managers(id),
    branch_id           INT             NOT NULL REFERENCES il_branches(id),
    employee_code       VARCHAR(20)     NOT NULL UNIQUE,
    full_name           VARCHAR(150)    NOT NULL,
    email               VARCHAR(150)    NOT NULL UNIQUE,
    phone               VARCHAR(20),
    monthly_target_inr  NUMERIC(14,2),
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    joined_on           DATE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_sales_managers IS 'SM — under territory manager';

CREATE INDEX idx_sm_tm ON il_sales_managers(tm_id);

-- 2.6  Relationship Managers (RM — under SM)
CREATE TABLE il_relationship_managers (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    sm_id               UUID            NOT NULL REFERENCES il_sales_managers(id),
    branch_id           INT             NOT NULL REFERENCES il_branches(id),
    employee_code       VARCHAR(20)     NOT NULL UNIQUE,
    full_name           VARCHAR(150)    NOT NULL,
    email               VARCHAR(150)    NOT NULL UNIQUE,
    phone               VARCHAR(20),
    monthly_target_inr  NUMERIC(14,2),
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    joined_on           DATE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_relationship_managers IS 'RM — under sales manager';

CREATE INDEX idx_rm_sm ON il_relationship_managers(sm_id);

-- 2.7  Agents (Under RM — direct policy sellers)
CREATE TABLE il_agents (
    id                  UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    rm_id               UUID            REFERENCES il_relationship_managers(id),
    branch_id           INT             NOT NULL REFERENCES il_branches(id),
    agent_code          VARCHAR(30)     NOT NULL UNIQUE,     -- IRDAI agent licence code
    irdai_licence_no    VARCHAR(30)     NOT NULL UNIQUE,
    full_name           VARCHAR(150)    NOT NULL,
    email               VARCHAR(150),
    phone               VARCHAR(20)     NOT NULL,
    agent_type          VARCHAR(20)     NOT NULL DEFAULT 'INDIVIDUAL'
                        CHECK (agent_type IN ('INDIVIDUAL','CORPORATE','BANK','BROKER')),
    specialisation      VARCHAR(20)[]   DEFAULT '{}',        -- ['HEALTH','MOTOR']
    monthly_target_inr  NUMERIC(12,2),
    licence_expiry      DATE,
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    joined_on           DATE,
    created_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_agents IS 'IRDAI-licensed agents — bottom of IL sales hierarchy';

CREATE INDEX idx_agents_rm     ON il_agents(rm_id);
CREATE INDEX idx_agents_branch ON il_agents(branch_id);
CREATE INDEX idx_agents_code   ON il_agents(agent_code);

-- =============================================================================
-- SECTION 3 : CUSTOMERS (POLICYHOLDERS)
-- =============================================================================

CREATE TABLE customers (
    id                      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    il_customer_id          VARCHAR(30)     UNIQUE,          -- IL's own CRM customer ID
    first_name              VARCHAR(80)     NOT NULL,
    last_name               VARCHAR(80)     NOT NULL,
    date_of_birth           DATE,
    gender                  CHAR(1)         CHECK (gender IN ('M','F','O')),
    pan_number              VARCHAR(10),                     -- for 80D claims
    aadhaar_last4           CHAR(4),                        -- last 4 digits only (privacy)
    email                   VARCHAR(150),
    phone                   VARCHAR(20)     NOT NULL,
    whatsapp_number         VARCHAR(20),
    alternate_phone         VARCHAR(20),
    address_line1           TEXT,
    address_line2           TEXT,
    city                    VARCHAR(80),
    state                   VARCHAR(80),
    pincode                 VARCHAR(10),
    preferred_channel_id    SMALLINT        REFERENCES channels(id),
    preferred_language_id   SMALLINT        REFERENCES languages(id),
    customer_segment        VARCHAR(20)
                            CHECK (customer_segment IN ('PLATINUM','GOLD','SILVER','STANDARD')),
    kyc_status              VARCHAR(20)     NOT NULL DEFAULT 'PENDING'
                            CHECK (kyc_status IN ('PENDING','VERIFIED','REJECTED','EXPIRED')),
    kyc_verified_at         TIMESTAMPTZ,
    is_nri                  BOOLEAN         NOT NULL DEFAULT FALSE,
    is_opted_out            BOOLEAN         NOT NULL DEFAULT FALSE,
    opted_out_at            TIMESTAMPTZ,
    opted_out_channel_id    SMALLINT        REFERENCES channels(id),
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE customers IS 'ICICI Lombard policyholders — single tenant, no org_id needed';

CREATE INDEX idx_customers_phone        ON customers(phone);
CREATE INDEX idx_customers_email        ON customers(email);
CREATE INDEX idx_customers_il_id        ON customers(il_customer_id);
CREATE INDEX idx_customers_opted_out    ON customers(is_opted_out)
    WHERE is_opted_out = FALSE;
CREATE INDEX idx_customers_name_trgm    ON customers
    USING GIN ((first_name || ' ' || last_name) gin_trgm_ops);

-- =============================================================================
-- SECTION 4 : POLICIES (CORE)
-- =============================================================================

CREATE TABLE policies (
    id                      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id             UUID            NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    product_id              SMALLINT        NOT NULL REFERENCES il_products(id),
    branch_id               INT             NOT NULL REFERENCES il_branches(id),
    agent_id                UUID            REFERENCES il_agents(id),
    rm_id                   UUID            REFERENCES il_relationship_managers(id),

    -- IL policy number
    il_policy_number        VARCHAR(30)     NOT NULL UNIQUE, -- e.g. 4128/2024/12345678
    policy_prefix           VARCHAR(10)     NOT NULL,        -- product-specific prefix
    endorsement_number      VARCHAR(20),                     -- if amended policy

    -- Coverage period
    risk_start_date         DATE            NOT NULL,
    risk_end_date           DATE            NOT NULL,
    issue_date              DATE            NOT NULL DEFAULT CURRENT_DATE,
    expiry_date             DATE            NOT NULL
                            GENERATED ALWAYS AS (risk_end_date) STORED,

    -- Financials
    sum_insured             NUMERIC(14,2)   NOT NULL CHECK (sum_insured > 0),
    basic_premium           NUMERIC(12,2)   NOT NULL CHECK (basic_premium > 0),
    net_premium             NUMERIC(12,2)   NOT NULL CHECK (net_premium > 0),
    gst_rate                NUMERIC(5,2)    NOT NULL DEFAULT 18.00,
    gst_amount              NUMERIC(10,2)   GENERATED ALWAYS AS
                                (ROUND(net_premium * gst_rate / 100, 2)) STORED,
    total_premium           NUMERIC(12,2)   GENERATED ALWAYS AS
                                (net_premium + ROUND(net_premium * gst_rate / 100, 2)) STORED,

    -- Payment
    payment_mode            VARCHAR(20)
                            CHECK (payment_mode IN
                                ('ANNUAL','HALF_YEARLY','QUARTERLY','MONTHLY','SINGLE')),
    payment_frequency       SMALLINT        DEFAULT 1,       -- number of installments

    -- Status
    policy_status           VARCHAR(20)     NOT NULL DEFAULT 'ACTIVE'
                            CHECK (policy_status IN
                                ('PROPOSAL','ACTIVE','EXPIRING','RENEWED',
                                 'LAPSED','CANCELLED','SUSPENDED')),
    is_first_policy         BOOLEAN         NOT NULL DEFAULT TRUE,
    last_renewed_at         TIMESTAMPTZ,
    renewal_count           SMALLINT        NOT NULL DEFAULT 0,
    cancellation_reason     TEXT,
    cancelled_at            TIMESTAMPTZ,

    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),

    CONSTRAINT chk_risk_dates CHECK (risk_end_date > risk_start_date)
);
COMMENT ON TABLE policies IS
    'Master policy table — all product lines share this with extension tables per product';

CREATE INDEX idx_policies_customer          ON policies(customer_id);
CREATE INDEX idx_policies_product           ON policies(product_id);
CREATE INDEX idx_policies_branch            ON policies(branch_id);
CREATE INDEX idx_policies_agent             ON policies(agent_id);
CREATE INDEX idx_policies_rm                ON policies(rm_id);
CREATE INDEX idx_policies_expiry_scan       ON policies(expiry_date, policy_status)
    WHERE policy_status IN ('ACTIVE','EXPIRING');
CREATE INDEX idx_policies_status            ON policies(policy_status);
CREATE INDEX idx_policies_issue_date        ON policies(issue_date);

-- =============================================================================
-- SECTION 5 : PRODUCT-SPECIFIC EXTENSION TABLES (1-to-1 with policies)
-- =============================================================================

-- 5.1  Health Policy Details (iHealth, Health Advantage, etc.)
CREATE TABLE il_health_details (
    policy_id               UUID            PRIMARY KEY REFERENCES policies(id) ON DELETE CASCADE,
    plan_variant            VARCHAR(50),                     -- INDIVIDUAL, FAMILY_FLOATER, SENIOR
    sum_insured_slab        VARCHAR(20),                     -- 3L, 5L, 10L, 25L, 50L, 1CR
    members_insured         SMALLINT        NOT NULL DEFAULT 1,
    copay_percent           NUMERIC(5,2)    NOT NULL DEFAULT 0,
    room_rent_limit_inr     NUMERIC(10,2),                   -- NULL = no limit
    pre_existing_wait_days  SMALLINT        NOT NULL DEFAULT 1095, -- 3 years standard
    maternity_covered       BOOLEAN         NOT NULL DEFAULT FALSE,
    maternity_wait_days     SMALLINT,
    covid_covered           BOOLEAN         NOT NULL DEFAULT TRUE,
    ayush_covered           BOOLEAN         NOT NULL DEFAULT FALSE,
    no_claim_bonus_pct      NUMERIC(5,2)    NOT NULL DEFAULT 0,
    cumulative_bonus_pct    NUMERIC(5,2)    NOT NULL DEFAULT 0,
    deductible_amount       NUMERIC(10,2)   NOT NULL DEFAULT 0,
    tpa_id                  VARCHAR(30),                     -- Third Party Administrator code
    network_hospital_count  INT,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_health_details IS '1:1 extension for health policies — iHealth, Health Advantage';

-- 5.2  Motor Policy Details (Private Car, Two Wheeler, Commercial Vehicle)
CREATE TABLE il_motor_details (
    policy_id               UUID            PRIMARY KEY REFERENCES policies(id) ON DELETE CASCADE,
    vehicle_type            VARCHAR(20)     NOT NULL
                            CHECK (vehicle_type IN
                                ('PRIVATE_CAR','TWO_WHEELER','COMMERCIAL_VEHICLE',
                                 'TAXI','GOODS_VEHICLE')),
    registration_number     VARCHAR(20)     NOT NULL,        -- MH12AB1234
    make                    VARCHAR(60)     NOT NULL,        -- Maruti, Hyundai, Honda
    model                   VARCHAR(80)     NOT NULL,        -- Swift, Creta, Activa
    variant                 VARCHAR(80),                     -- LXI, VXI, ZXI
    manufacture_year        SMALLINT        NOT NULL,
    fuel_type               VARCHAR(15)     NOT NULL
                            CHECK (fuel_type IN ('PETROL','DIESEL','CNG','ELECTRIC','HYBRID')),
    engine_number           VARCHAR(30),
    chassis_number          VARCHAR(30),
    engine_cc               SMALLINT,
    seating_capacity        SMALLINT,
    rto_code                VARCHAR(10)     NOT NULL,        -- MH12, DL01
    hypothecation_bank      VARCHAR(100),                    -- if on loan
    policy_type             VARCHAR(15)     NOT NULL
                            CHECK (policy_type IN
                                ('COMPREHENSIVE','THIRD_PARTY','OWN_DAMAGE')),
    idv_amount              NUMERIC(12,2)   NOT NULL,        -- Insured Declared Value
    idv_agreed              BOOLEAN         NOT NULL DEFAULT FALSE,
    ncb_percent             NUMERIC(5,2)    NOT NULL DEFAULT 0
                            CHECK (ncb_percent IN (0,20,25,35,45,50)),
    ncb_certificate_no      VARCHAR(30),
    pa_cover_owner          BOOLEAN         NOT NULL DEFAULT TRUE,
    pa_cover_amount         NUMERIC(10,2),
    nil_depreciation        BOOLEAN         NOT NULL DEFAULT FALSE,
    roadside_assistance     BOOLEAN         NOT NULL DEFAULT FALSE,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_motor_details IS '1:1 extension for motor policies — Car, Two Wheeler, CV';

CREATE INDEX idx_motor_reg_number   ON il_motor_details(registration_number);
CREATE INDEX idx_motor_vehicle_type ON il_motor_details(vehicle_type);

-- 5.3  Travel Policy Details
CREATE TABLE il_travel_details (
    policy_id               UUID            PRIMARY KEY REFERENCES policies(id) ON DELETE CASCADE,
    trip_type               VARCHAR(20)     NOT NULL
                            CHECK (trip_type IN
                                ('SINGLE_TRIP','MULTI_TRIP','STUDENT','SENIOR_CITIZEN')),
    travel_type             VARCHAR(15)     NOT NULL
                            CHECK (travel_type IN ('DOMESTIC','INTERNATIONAL')),
    destination_region      VARCHAR(50),                     -- SCHENGEN, USA_CANADA, ASIA etc.
    departure_date          DATE            NOT NULL,
    return_date             DATE            NOT NULL,
    trip_duration_days      SMALLINT        NOT NULL
                            GENERATED ALWAYS AS
                                ((return_date - departure_date)::SMALLINT) STORED,
    traveller_count         SMALLINT        NOT NULL DEFAULT 1,
    medical_cover_usd       NUMERIC(12,2),
    trip_cancellation_cover BOOLEAN         NOT NULL DEFAULT FALSE,
    baggage_loss_cover      BOOLEAN         NOT NULL DEFAULT FALSE,
    passport_loss_cover     BOOLEAN         NOT NULL DEFAULT FALSE,
    adventure_sports_cover  BOOLEAN         NOT NULL DEFAULT FALSE,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_travel_details IS '1:1 extension for travel policies — domestic and international';

-- 5.4  Home Policy Details (Bharat Griha Raksha / Home Shield)
CREATE TABLE il_home_details (
    policy_id               UUID            PRIMARY KEY REFERENCES policies(id) ON DELETE CASCADE,
    property_type           VARCHAR(20)     NOT NULL
                            CHECK (property_type IN
                                ('OWNED_FLAT','OWNED_HOUSE','RENTED','UNDER_CONSTRUCTION')),
    construction_type       VARCHAR(20)     NOT NULL
                            CHECK (construction_type IN
                                ('RCC','SEMI_RCC','KATCHA','PREFABRICATED')),
    built_up_area_sqft      INT             NOT NULL,
    property_age_years      SMALLINT,
    floors                  SMALLINT,
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
    rent_cover              BOOLEAN         NOT NULL DEFAULT FALSE,
    mortgage_bank           VARCHAR(100),
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_home_details IS '1:1 extension for home/property insurance policies';

-- 5.5  Commercial / SME Policy Details
CREATE TABLE il_commercial_details (
    policy_id               UUID            PRIMARY KEY REFERENCES policies(id) ON DELETE CASCADE,
    commercial_type         VARCHAR(30)     NOT NULL
                            CHECK (commercial_type IN
                                ('FIRE','BURGLARY','MARINE_CARGO','MARINE_HULL',
                                 'LIABILITY','WORKMEN_COMP','GROUP_HEALTH',
                                 'SHOP_KEEPER','OFFICE_PACKAGE','CYBER')),
    business_name           VARCHAR(200)    NOT NULL,
    gstin                   VARCHAR(20),
    industry_code           VARCHAR(10),                     -- NIC industry code
    premises_address        TEXT,
    premises_sqft           INT,
    stock_value_inr         NUMERIC(16,2),
    plant_machinery_inr     NUMERIC(16,2),
    employee_count          INT,
    annual_turnover_inr     NUMERIC(18,2),
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_commercial_details IS '1:1 extension for commercial/SME insurance policies';

-- 5.6  Life / Term Policy Details
CREATE TABLE il_life_details (
    policy_id               UUID            PRIMARY KEY REFERENCES policies(id) ON DELETE CASCADE,
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
    maturity_benefit_inr    NUMERIC(16,2),
    surrender_value_inr     NUMERIC(14,2),
    medical_underwriting    BOOLEAN         NOT NULL DEFAULT FALSE,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_life_details IS '1:1 extension for life/term insurance policies';

-- =============================================================================
-- SECTION 6 : INSURED MEMBERS & NOMINEES
-- =============================================================================

-- 6.1  Insured Members (for health/travel — multiple members per policy)
CREATE TABLE insured_members (
    id                      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_id               UUID            NOT NULL REFERENCES policies(id) ON DELETE CASCADE,
    customer_id             UUID            REFERENCES customers(id),    -- if existing customer
    member_type             VARCHAR(20)     NOT NULL
                            CHECK (member_type IN
                                ('SELF','SPOUSE','CHILD','PARENT',
                                 'PARENT_IN_LAW','SIBLING')),
    full_name               VARCHAR(150)    NOT NULL,
    date_of_birth           DATE            NOT NULL,
    gender                  CHAR(1)         CHECK (gender IN ('M','F','O')),
    relation_to_proposer    VARCHAR(30)     NOT NULL,
    pre_existing_disease    TEXT,                            -- free text description
    is_primary_insured      BOOLEAN         NOT NULL DEFAULT FALSE,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE insured_members IS 'All insured persons under a policy (health floater, travel group)';

CREATE INDEX idx_members_policy ON insured_members(policy_id);

-- 6.2  Nominees (for life policies)
CREATE TABLE il_nominees (
    id                      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_id               UUID            NOT NULL REFERENCES policies(id) ON DELETE CASCADE,
    full_name               VARCHAR(150)    NOT NULL,
    date_of_birth           DATE,
    relation_to_insured     VARCHAR(40)     NOT NULL,
    share_percent           NUMERIC(5,2)    NOT NULL CHECK (share_percent > 0 AND share_percent <= 100),
    contact_phone           VARCHAR(20),
    address                 TEXT,
    is_minor                BOOLEAN         NOT NULL DEFAULT FALSE,
    appointee_name          VARCHAR(150),                    -- guardian if nominee is minor
    appointee_relation      VARCHAR(40),
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_nominees IS 'Policy nominees — primarily for life/term policies';

CREATE INDEX idx_nominees_policy ON il_nominees(policy_id);

-- Ensure nominee shares sum to 100% (enforced by trigger or app logic)
-- Total share per policy_id must = 100

-- =============================================================================
-- SECTION 7 : CAMPAIGNS & RENEWAL ORCHESTRATION
-- =============================================================================

-- 7.1  Campaigns
CREATE TABLE campaigns (
    id                      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    name                    VARCHAR(150)    NOT NULL,
    description             TEXT,
    product_line            VARCHAR(20)
                            CHECK (product_line IN
                                ('HEALTH','MOTOR','TRAVEL','HOME',
                                 'COMMERCIAL','LIFE','ALL')),
    target_segment          VARCHAR(20)
                            CHECK (target_segment IN
                                ('PLATINUM','GOLD','SILVER','STANDARD','ALL')),
    reminder_window         VARCHAR(10)     NOT NULL
                            CHECK (reminder_window IN ('30DAY','15DAY','7DAY','3DAY','ALL')),
    branch_id               INT             REFERENCES il_branches(id),  -- NULL = all branches
    zone_id                 SMALLINT        REFERENCES il_zones(id),      -- NULL = all zones
    status                  VARCHAR(20)     NOT NULL DEFAULT 'DRAFT'
                            CHECK (status IN
                                ('DRAFT','RUNNING','PAUSED','COMPLETED','CANCELLED')),
    scheduled_start         TIMESTAMPTZ,
    scheduled_end           TIMESTAMPTZ,
    created_by              UUID,                            -- user/admin UUID
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE campaigns IS 'IL renewal outreach campaigns — can target by product, segment, branch or zone';

CREATE INDEX idx_campaigns_status   ON campaigns(status);
CREATE INDEX idx_campaigns_product  ON campaigns(product_line);

-- 7.2  Campaign Channel Config (M:M with fallback order)
CREATE TABLE campaign_channels (
    campaign_id             UUID            NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
    channel_id              SMALLINT        NOT NULL REFERENCES channels(id),
    fallback_order          SMALLINT        NOT NULL DEFAULT 1,
    wait_hours              SMALLINT        NOT NULL DEFAULT 24,
    is_enabled              BOOLEAN         NOT NULL DEFAULT TRUE,
    PRIMARY KEY (campaign_id, channel_id),
    UNIQUE (campaign_id, fallback_order)
);

-- =============================================================================
-- SECTION 8 : RENEWAL TOKENS
-- =============================================================================

CREATE TABLE renewal_tokens (
    id                      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_id               UUID            NOT NULL REFERENCES policies(id) ON DELETE CASCADE,
    customer_id             UUID            NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    campaign_id             UUID            REFERENCES campaigns(id),
    channel_id              SMALLINT        NOT NULL REFERENCES channels(id),
    token_hash              VARCHAR(512)    NOT NULL UNIQUE,  -- SHA-256 of JWT
    short_code              VARCHAR(20)     NOT NULL UNIQUE,
    short_url               TEXT            NOT NULL,
    issued_at               TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    expires_at              TIMESTAMPTZ     NOT NULL,
    is_used                 BOOLEAN         NOT NULL DEFAULT FALSE,
    used_at                 TIMESTAMPTZ,
    is_invalidated          BOOLEAN         NOT NULL DEFAULT FALSE,
    invalidated_at          TIMESTAMPTZ,
    invalidation_reason     VARCHAR(100),
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE renewal_tokens IS 'Single-use JWT-backed renewal links — hash stored, never plain token';

CREATE INDEX idx_tokens_policy   ON renewal_tokens(policy_id);
CREATE INDEX idx_tokens_customer ON renewal_tokens(customer_id);
CREATE INDEX idx_tokens_code     ON renewal_tokens(short_code);
CREATE INDEX idx_tokens_active   ON renewal_tokens(is_used, is_invalidated, expires_at)
    WHERE is_used = FALSE AND is_invalidated = FALSE;

-- =============================================================================
-- SECTION 9 : REMINDERS (MASTER OUTREACH LOG)
-- =============================================================================

CREATE TABLE reminders (
    id                      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id             UUID            REFERENCES campaigns(id),
    policy_id               UUID            NOT NULL REFERENCES policies(id) ON DELETE CASCADE,
    customer_id             UUID            NOT NULL REFERENCES customers(id) ON DELETE CASCADE,
    token_id                UUID            REFERENCES renewal_tokens(id),
    channel_id              SMALLINT        NOT NULL REFERENCES channels(id),
    template_id             INT             REFERENCES message_templates(id),
    reminder_window         VARCHAR(10)     NOT NULL
                            CHECK (reminder_window IN ('30DAY','15DAY','7DAY','3DAY')),
    attempt_number          SMALLINT        NOT NULL DEFAULT 1,
    is_fallback             BOOLEAN         NOT NULL DEFAULT FALSE,
    parent_reminder_id      UUID            REFERENCES reminders(id),
    scheduled_at            TIMESTAMPTZ     NOT NULL,
    sent_at                 TIMESTAMPTZ,
    delivery_status         VARCHAR(20)     NOT NULL DEFAULT 'PENDING'
                            CHECK (delivery_status IN
                                ('PENDING','SENT','DELIVERED','READ','CLICKED',
                                 'NO_RESPONSE','FAILED','CANCELLED')),
    link_clicked            BOOLEAN         NOT NULL DEFAULT FALSE,
    clicked_at              TIMESTAMPTZ,
    renewed_after_click     BOOLEAN         NOT NULL DEFAULT FALSE,
    fallback_triggered      BOOLEAN         NOT NULL DEFAULT FALSE,
    fallback_reminder_id    UUID            REFERENCES reminders(id),
    agent_notes             TEXT,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE reminders IS 'Master outreach log — every message across all 4 channels';

CREATE INDEX idx_reminders_policy      ON reminders(policy_id);
CREATE INDEX idx_reminders_customer    ON reminders(customer_id);
CREATE INDEX idx_reminders_campaign    ON reminders(campaign_id);
CREATE INDEX idx_reminders_status      ON reminders(delivery_status);
CREATE INDEX idx_reminders_scheduled   ON reminders(scheduled_at)
    WHERE delivery_status = 'PENDING';
CREATE INDEX idx_reminders_channel_date ON reminders(channel_id, sent_at);

-- =============================================================================
-- SECTION 10 : CHANNEL-SPECIFIC LOGS
-- =============================================================================

-- 10.1  WhatsApp Log
CREATE TABLE whatsapp_logs (
    id                      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    reminder_id             UUID            NOT NULL REFERENCES reminders(id) ON DELETE CASCADE,
    meta_message_id         VARCHAR(100)    UNIQUE,
    wa_number               VARCHAR(20)     NOT NULL,
    template_name           VARCHAR(100),
    message_preview         TEXT,
    sent_at                 TIMESTAMPTZ,
    delivered_at            TIMESTAMPTZ,
    read_at                 TIMESTAMPTZ,
    delivery_status         VARCHAR(20)     NOT NULL DEFAULT 'SENT'
                            CHECK (delivery_status IN ('SENT','DELIVERED','READ','FAILED')),
    button_clicked          VARCHAR(50),
    reply_received          BOOLEAN         NOT NULL DEFAULT FALSE,
    reply_text              TEXT,
    replied_at              TIMESTAMPTZ,
    error_code              VARCHAR(20),
    error_message           TEXT,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_wa_reminder  ON whatsapp_logs(reminder_id);
CREATE INDEX idx_wa_read      ON whatsapp_logs(read_at) WHERE read_at IS NOT NULL;

-- 10.2  SMS Log
CREATE TABLE sms_logs (
    id                      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    reminder_id             UUID            NOT NULL REFERENCES reminders(id) ON DELETE CASCADE,
    provider                VARCHAR(30)     NOT NULL,
    provider_msg_id         VARCHAR(100)    UNIQUE,
    phone_number            VARCHAR(20)     NOT NULL,
    sender_id               VARCHAR(20),
    message_text            TEXT            NOT NULL,
    dlt_template_id         VARCHAR(50),
    sent_at                 TIMESTAMPTZ,
    delivered_at            TIMESTAMPTZ,
    delivery_status         VARCHAR(20)     NOT NULL DEFAULT 'SENT'
                            CHECK (delivery_status IN
                                ('SENT','DELIVERED','FAILED','REJECTED')),
    is_opted_out            BOOLEAN         NOT NULL DEFAULT FALSE,
    opted_out_at            TIMESTAMPTZ,
    cost_inr                NUMERIC(6,4),
    error_code              VARCHAR(20),
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_sms_reminder ON sms_logs(reminder_id);
CREATE INDEX idx_sms_phone    ON sms_logs(phone_number);

-- 10.3  Email Log
CREATE TABLE email_logs (
    id                      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    reminder_id             UUID            NOT NULL REFERENCES reminders(id) ON DELETE CASCADE,
    provider                VARCHAR(30)     NOT NULL,
    provider_msg_id         VARCHAR(150)    UNIQUE,
    to_email                VARCHAR(150)    NOT NULL,
    from_email              VARCHAR(150)    NOT NULL,
    subject                 VARCHAR(250)    NOT NULL,
    template_name           VARCHAR(100),
    sent_at                 TIMESTAMPTZ,
    opened_at               TIMESTAMPTZ,
    clicked_at              TIMESTAMPTZ,
    delivery_status         VARCHAR(20)     NOT NULL DEFAULT 'SENT'
                            CHECK (delivery_status IN
                                ('SENT','DELIVERED','OPENED','CLICKED',
                                 'BOUNCED','SPAM','FAILED')),
    bounce_type             VARCHAR(10)     CHECK (bounce_type IN ('HARD','SOFT')),
    is_unsubscribed         BOOLEAN         NOT NULL DEFAULT FALSE,
    unsubscribed_at         TIMESTAMPTZ,
    open_count              SMALLINT        NOT NULL DEFAULT 0,
    click_count             SMALLINT        NOT NULL DEFAULT 0,
    error_code              VARCHAR(20),
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_email_reminder ON email_logs(reminder_id);
CREATE INDEX idx_email_opened   ON email_logs(opened_at) WHERE opened_at IS NOT NULL;

-- 10.4  Voice Call Log
CREATE TABLE voice_logs (
    id                      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    reminder_id             UUID            NOT NULL REFERENCES reminders(id) ON DELETE CASCADE,
    phone_number            VARCHAR(20)     NOT NULL,
    trigger_endpoint        TEXT,
    script_version          VARCHAR(30),
    initiated_at            TIMESTAMPTZ     NOT NULL,
    answered_at             TIMESTAMPTZ,
    ended_at                TIMESTAMPTZ,
    duration_seconds        INT,
    call_outcome            VARCHAR(30)     NOT NULL DEFAULT 'PENDING'
                            CHECK (call_outcome IN
                                ('PENDING','ANSWERED_INTERESTED',
                                 'ANSWERED_NOT_INTERESTED','NO_ANSWER',
                                 'VOICEMAIL','CALL_FAILED','ANSWERED_CALLBACK')),
    ivr_key_pressed         VARCHAR(5),
    is_interested           BOOLEAN,
    callback_requested      BOOLEAN         NOT NULL DEFAULT FALSE,
    callback_time           TIMESTAMPTZ,
    retry_number            SMALLINT        NOT NULL DEFAULT 1,
    error_reason            VARCHAR(100),
    recording_url           TEXT,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_voice_reminder  ON voice_logs(reminder_id);
CREATE INDEX idx_voice_outcome   ON voice_logs(call_outcome);
CREATE INDEX idx_voice_callback  ON voice_logs(callback_requested, callback_time)
    WHERE callback_requested = TRUE;

-- =============================================================================
-- SECTION 11 : CLAIMS (IL-SPECIFIC)
-- =============================================================================

CREATE TABLE il_claims (
    id                      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_id               UUID            NOT NULL REFERENCES policies(id),
    customer_id             UUID            NOT NULL REFERENCES customers(id),
    claim_number            VARCHAR(30)     NOT NULL UNIQUE, -- IL claim number
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
    surveyor_name           VARCHAR(150),
    hospital_name           VARCHAR(200),                    -- health claims
    tpa_claim_id            VARCHAR(30),                     -- TPA reference
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE il_claims IS 'Claim records — affects NCB for motor, renewal eligibility for all';

CREATE INDEX idx_claims_policy   ON il_claims(policy_id);
CREATE INDEX idx_claims_customer ON il_claims(customer_id);
CREATE INDEX idx_claims_status   ON il_claims(claim_status);
CREATE INDEX idx_claims_number   ON il_claims(claim_number);

-- =============================================================================
-- SECTION 12 : PAYMENTS
-- =============================================================================

CREATE TABLE payments (
    id                      UUID            PRIMARY KEY DEFAULT gen_random_uuid(),
    policy_id               UUID            NOT NULL REFERENCES policies(id) ON DELETE CASCADE,
    customer_id             UUID            NOT NULL REFERENCES customers(id),
    token_id                UUID            REFERENCES renewal_tokens(id),
    reminder_id             UUID            REFERENCES reminders(id),
    campaign_id             UUID            REFERENCES campaigns(id),
    channel_source_id       SMALLINT        REFERENCES channels(id),
    gateway                 VARCHAR(30)     NOT NULL,
    gateway_order_id        VARCHAR(100)    UNIQUE,
    gateway_txn_id          VARCHAR(150)    UNIQUE,
    amount_inr              NUMERIC(12,2)   NOT NULL CHECK (amount_inr > 0),
    gst_inr                 NUMERIC(10,2)   NOT NULL DEFAULT 0,
    total_inr               NUMERIC(12,2)   NOT NULL CHECK (total_inr > 0),
    payment_method          VARCHAR(30),
    status                  VARCHAR(20)     NOT NULL DEFAULT 'INITIATED'
                            CHECK (status IN
                                ('INITIATED','COMPLETED','FAILED','REFUNDED','PENDING')),
    initiated_at            TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    completed_at            TIMESTAMPTZ,
    policy_renewed_from     DATE,
    policy_renewed_to       DATE,
    confirmation_channels   TEXT[],
    failure_reason          VARCHAR(200),
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE payments IS 'Renewal payment transactions with full attribution to campaign and channel';

CREATE INDEX idx_payments_policy    ON payments(policy_id);
CREATE INDEX idx_payments_customer  ON payments(customer_id);
CREATE INDEX idx_payments_status    ON payments(status);
CREATE INDEX idx_payments_completed ON payments(completed_at)
    WHERE status = 'COMPLETED';
CREATE INDEX idx_payments_campaign  ON payments(campaign_id)
    WHERE campaign_id IS NOT NULL;

-- =============================================================================
-- SECTION 13 : ANALYTICS (PRE-AGGREGATED)
-- =============================================================================

-- 13.1  Daily KPI Snapshot
CREATE TABLE analytics_daily (
    id                      BIGSERIAL       PRIMARY KEY,
    snapshot_date           DATE            NOT NULL UNIQUE,
    product_line            VARCHAR(20)     NOT NULL DEFAULT 'ALL'
                            CHECK (product_line IN
                                ('HEALTH','MOTOR','TRAVEL','HOME',
                                 'COMMERCIAL','LIFE','ALL')),
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
    fallbacks_triggered     INT             NOT NULL DEFAULT 0,
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

CREATE INDEX idx_analytics_date_product ON analytics_daily(snapshot_date DESC, product_line);

-- 13.2  Branch Performance (IL-specific — track by branch)
CREATE TABLE analytics_branch_daily (
    id                      BIGSERIAL       PRIMARY KEY,
    branch_id               INT             NOT NULL REFERENCES il_branches(id),
    snapshot_date           DATE            NOT NULL,
    reminders_sent          INT             NOT NULL DEFAULT 0,
    renewals_completed      INT             NOT NULL DEFAULT 0,
    revenue_inr             NUMERIC(14,2)   NOT NULL DEFAULT 0,
    renewal_rate_pct        NUMERIC(5,2)    GENERATED ALWAYS AS (
        CASE WHEN reminders_sent > 0
             THEN ROUND(renewals_completed::NUMERIC / reminders_sent * 100, 2)
             ELSE 0 END
    ) STORED,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    UNIQUE (branch_id, snapshot_date)
);

CREATE INDEX idx_branch_analytics ON analytics_branch_daily(branch_id, snapshot_date DESC);

-- 13.3  Agent Performance (IL-specific — track by agent)
CREATE TABLE analytics_agent_daily (
    id                      BIGSERIAL       PRIMARY KEY,
    agent_id                UUID            NOT NULL REFERENCES il_agents(id),
    snapshot_date           DATE            NOT NULL,
    policies_expiring       INT             NOT NULL DEFAULT 0,
    reminders_sent          INT             NOT NULL DEFAULT 0,
    renewals_completed      INT             NOT NULL DEFAULT 0,
    revenue_inr             NUMERIC(14,2)   NOT NULL DEFAULT 0,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    UNIQUE (agent_id, snapshot_date)
);

CREATE INDEX idx_agent_analytics ON analytics_agent_daily(agent_id, snapshot_date DESC);

-- 13.4  Channel Performance Daily
CREATE TABLE analytics_channel_daily (
    id                      BIGSERIAL       PRIMARY KEY,
    channel_id              SMALLINT        NOT NULL REFERENCES channels(id),
    snapshot_date           DATE            NOT NULL,
    sent                    INT             NOT NULL DEFAULT 0,
    delivered               INT             NOT NULL DEFAULT 0,
    opened                  INT             NOT NULL DEFAULT 0,
    clicked                 INT             NOT NULL DEFAULT 0,
    renewed                 INT             NOT NULL DEFAULT 0,
    failed                  INT             NOT NULL DEFAULT 0,
    opt_outs                INT             NOT NULL DEFAULT 0,
    cost_inr                NUMERIC(12,2)   NOT NULL DEFAULT 0,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    UNIQUE (channel_id, snapshot_date)
);

CREATE INDEX idx_ch_analytics ON analytics_channel_daily(channel_id, snapshot_date DESC);

-- =============================================================================
-- SECTION 14 : AUDIT LOG
-- =============================================================================

CREATE TABLE audit_logs (
    id                      BIGSERIAL       PRIMARY KEY,
    entity_type             VARCHAR(50)     NOT NULL,
    entity_id               TEXT            NOT NULL,
    action                  VARCHAR(30)     NOT NULL
                            CHECK (action IN
                                ('INSERT','UPDATE','DELETE','STATUS_CHANGE',
                                 'OPT_OUT','LOGIN','PAYMENT')),
    old_values              JSONB,
    new_values              JSONB,
    performed_by            UUID,
    ip_address              INET,
    user_agent              TEXT,
    created_at              TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE audit_logs IS 'Append-only audit trail — never UPDATE or DELETE from this table';

CREATE INDEX idx_audit_entity    ON audit_logs(entity_type, entity_id);
CREATE INDEX idx_audit_date      ON audit_logs(created_at DESC);
CREATE INDEX idx_audit_performer ON audit_logs(performed_by)
    WHERE performed_by IS NOT NULL;

-- =============================================================================
-- SECTION 15 : TRIGGER — AUTO updated_at
-- =============================================================================

CREATE OR REPLACE FUNCTION trigger_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
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
        'il_health_details','il_motor_details','il_travel_details',
        'il_home_details','il_commercial_details','il_life_details',
        'insured_members','il_nominees',
        'campaigns','campaign_channels',
        'renewal_tokens','reminders',
        'whatsapp_logs','sms_logs','email_logs','voice_logs',
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
-- SECTION 16 : SEED DATA
-- =============================================================================

-- Channels
INSERT INTO channels (code, label, default_wait_hrs, daily_limit, rate_limit_per_sec) VALUES
    ('WHATSAPP', 'WhatsApp',    4,  5000,  80),
    ('SMS',      'SMS',         8,  10000, 100),
    ('EMAIL',    'Email',       24, 50000, 500),
    ('VOICE',    'Voice Call',  48, 1000,  20);

-- Languages
INSERT INTO languages (code, label) VALUES
    ('en', 'English'), ('hi', 'Hindi'), ('mr', 'Marathi'),
    ('ta', 'Tamil'),   ('te', 'Telugu'), ('kn', 'Kannada'),
    ('bn', 'Bengali'), ('gu', 'Gujarati'), ('pa', 'Punjabi');

-- IL Zones
INSERT INTO il_zones (zone_code, zone_name, hq_city) VALUES
    ('NORTH',   'North Zone',   'New Delhi'),
    ('SOUTH',   'South Zone',   'Chennai'),
    ('EAST',    'East Zone',    'Kolkata'),
    ('WEST',    'West Zone',    'Mumbai'),
    ('CENTRAL', 'Central Zone', 'Bhopal');

-- IL Products (key ones)
INSERT INTO il_products
    (product_code, product_name, product_line, policy_prefix, gst_rate) VALUES
    ('IHEALTH_IND',  'iHealth Individual',         'HEALTH',     '4128', 18.00),
    ('IHEALTH_FAM',  'iHealth Family Floater',      'HEALTH',     '4128', 18.00),
    ('HLTH_ADV',     'Health Advantage',            'HEALTH',     '4128', 18.00),
    ('HLTH_SUPRA',   'Health Supra Top-Up',         'HEALTH',     '4128', 18.00),
    ('MOTOR_PC',     'Private Car Package',         'MOTOR',      '3001', 18.00),
    ('MOTOR_TW',     'Two Wheeler Package',         'MOTOR',      '3002', 18.00),
    ('MOTOR_CV',     'Commercial Vehicle',          'MOTOR',      '3003', 18.00),
    ('MOTOR_TP',     'Motor Third Party',           'MOTOR',      '3004', 18.00),
    ('TRAVEL_ST',    'Travel Single Trip',          'TRAVEL',     '4003', 18.00),
    ('TRAVEL_MT',    'Travel Multi Trip Annual',    'TRAVEL',     '4003', 18.00),
    ('TRAVEL_STU',   'Student Travel',              'TRAVEL',     '4003', 18.00),
    ('HOME_SHIELD',  'Home Shield',                 'HOME',       '4150', 18.00),
    ('BHARAT_GRIHA', 'Bharat Griha Raksha',         'HOME',       '4150', 18.00),
    ('SME_SHOP',     'Shopkeeper Policy',           'COMMERCIAL', '5001', 18.00),
    ('SME_OFFICE',   'Office Package Policy',       'COMMERCIAL', '5002', 18.00),
    ('SME_FIRE',     'Standard Fire & Special Perils','COMMERCIAL','5003', 18.00),
    ('IL_TERM',      'iProtect Smart Term Plan',    'LIFE',       '6001', 18.00),
    ('IL_ULIP',      'Signature ULIP',              'LIFE',       '6002', 18.00);

-- =============================================================================
-- END OF SCHEMA
-- =============================================================================
