-- =============================================================================
-- Multi-Tenant Platform - Database Initialization
-- =============================================================================
-- Creates individual databases for each app
-- Run once on initial setup
-- =============================================================================

-- Create databases for each app
CREATE DATABASE filter_ical_production;
CREATE DATABASE filter_ical_staging;
CREATE DATABASE gabs_massage_production;
CREATE DATABASE gabs_massage_staging;

-- Grant privileges (apps will use platform_admin user)
GRANT ALL PRIVILEGES ON DATABASE filter_ical_production TO platform_admin;
GRANT ALL PRIVILEGES ON DATABASE filter_ical_staging TO platform_admin;
GRANT ALL PRIVILEGES ON DATABASE gabs_massage_production TO platform_admin;
GRANT ALL PRIVILEGES ON DATABASE gabs_massage_staging TO platform_admin;
