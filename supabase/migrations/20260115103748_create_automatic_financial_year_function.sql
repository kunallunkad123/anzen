/*
  # Automatic Financial Year Calculation
  
  1. Purpose
    - Automatically determine current financial year based on FY start date
    - No manual updates needed each year
    - Frontend calls this function to get current FY year code
  
  2. Logic
    - Read financial_year_start from app_settings
    - Compare current date with FY start date
    - If current date >= FY start of this year, use this year
    - Otherwise, use previous year
  
  3. Example
    - FY starts Jan 1
    - Current date: Jan 15, 2026 → returns '26'
    - Current date: Dec 30, 2025 → returns '25'
    
    - FY starts Apr 1  
    - Current date: May 1, 2026 → returns '26'
    - Current date: Feb 1, 2026 → returns '25' (still in FY 2025)
*/

CREATE OR REPLACE FUNCTION get_current_financial_year()
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_fy_start_date DATE;
  v_fy_start_month INT;
  v_fy_start_day INT;
  v_current_date DATE;
  v_current_year INT;
  v_this_year_fy_start DATE;
  v_fy_year INT;
BEGIN
  -- Get financial year start date from settings
  SELECT financial_year_start INTO v_fy_start_date
  FROM app_settings
  LIMIT 1;
  
  -- If not set, default to current year Jan 1
  IF v_fy_start_date IS NULL THEN
    v_fy_start_date := MAKE_DATE(EXTRACT(YEAR FROM CURRENT_DATE)::INT, 1, 1);
  END IF;
  
  -- Extract month and day from FY start
  v_fy_start_month := EXTRACT(MONTH FROM v_fy_start_date)::INT;
  v_fy_start_day := EXTRACT(DAY FROM v_fy_start_date)::INT;
  
  -- Get current date and year
  v_current_date := CURRENT_DATE;
  v_current_year := EXTRACT(YEAR FROM v_current_date)::INT;
  
  -- Calculate this year's FY start date
  v_this_year_fy_start := MAKE_DATE(v_current_year, v_fy_start_month, v_fy_start_day);
  
  -- Determine which FY we're in
  IF v_current_date >= v_this_year_fy_start THEN
    -- We're in the current year's FY
    v_fy_year := v_current_year;
  ELSE
    -- We're still in the previous year's FY
    v_fy_year := v_current_year - 1;
  END IF;
  
  -- Return 2-digit year code (e.g., '26' for 2026)
  RETURN RIGHT(v_fy_year::TEXT, 2);
END;
$$;

-- Grant access to authenticated users
GRANT EXECUTE ON FUNCTION get_current_financial_year() TO authenticated;

COMMENT ON FUNCTION get_current_financial_year IS
'Automatically calculates current financial year based on app_settings.financial_year_start. Returns 2-digit year code (e.g., "26" for 2026). No manual updates needed.';

-- Test the function
DO $$
DECLARE
  v_fy_year TEXT;
BEGIN
  v_fy_year := get_current_financial_year();
  RAISE NOTICE '✅ Current Financial Year: %', v_fy_year;
  RAISE NOTICE 'This will be used automatically for all document numbering';
END $$;
