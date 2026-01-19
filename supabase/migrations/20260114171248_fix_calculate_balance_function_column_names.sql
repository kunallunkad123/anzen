/*
  # Fix Calculate Balance Function - Correct Column Names

  1. Problem
    - Function uses from_account_id and to_account_id
    - Actual columns are from_bank_account_id and to_bank_account_id
    - This causes the function to fail with "column does not exist" error

  2. Solution
    - Update function to use correct column names
*/

-- Drop the broken function
DROP FUNCTION IF EXISTS calculate_balance_between_dates(UUID, DATE, DATE);

-- Create corrected function with proper column names
CREATE OR REPLACE FUNCTION calculate_balance_between_dates(
  p_bank_account_id UUID,
  p_start_date DATE,
  p_end_date DATE
)
RETURNS TABLE (net_change NUMERIC)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH all_transactions AS (
    -- Bank statement lines (actual bank transactions)
    SELECT
      COALESCE(credit_amount, 0) AS credit,
      COALESCE(debit_amount, 0) AS debit
    FROM bank_statement_lines
    WHERE bank_account_id = p_bank_account_id
      AND transaction_date >= p_start_date
      AND transaction_date < p_end_date

    UNION ALL

    -- Receipt vouchers (customer payments - money IN)
    SELECT
      amount AS credit,
      0 AS debit
    FROM receipt_vouchers
    WHERE bank_account_id = p_bank_account_id
      AND voucher_date >= p_start_date
      AND voucher_date < p_end_date

    UNION ALL

    -- Payment vouchers (supplier payments - money OUT)
    SELECT
      0 AS credit,
      amount AS debit
    FROM payment_vouchers
    WHERE bank_account_id = p_bank_account_id
      AND voucher_date >= p_start_date
      AND voucher_date < p_end_date

    UNION ALL

    -- Finance expenses paid by bank (money OUT)
    SELECT
      0 AS credit,
      amount AS debit
    FROM finance_expenses
    WHERE bank_account_id = p_bank_account_id
      AND expense_date >= p_start_date
      AND expense_date < p_end_date

    UNION ALL

    -- Fund transfers FROM this account (money OUT)
    SELECT
      0 AS credit,
      from_amount AS debit
    FROM fund_transfers
    WHERE from_bank_account_id = p_bank_account_id
      AND transfer_date >= p_start_date
      AND transfer_date < p_end_date

    UNION ALL

    -- Fund transfers TO this account (money IN)
    SELECT
      to_amount AS credit,
      0 AS debit
    FROM fund_transfers
    WHERE to_bank_account_id = p_bank_account_id
      AND transfer_date >= p_start_date
      AND transfer_date < p_end_date

    UNION ALL

    -- Petty cash replenishment FROM bank (money OUT)
    SELECT
      0 AS credit,
      amount AS debit
    FROM petty_cash
    WHERE bank_account_id = p_bank_account_id
      AND transaction_date >= p_start_date
      AND transaction_date < p_end_date
      AND transaction_type = 'replenishment'

    UNION ALL

    -- Petty cash deposit TO bank (money IN)
    SELECT
      amount AS credit,
      0 AS debit
    FROM petty_cash
    WHERE bank_account_id = p_bank_account_id
      AND transaction_date >= p_start_date
      AND transaction_date < p_end_date
      AND transaction_type = 'deposit'
  )
  SELECT
    COALESCE(SUM(credit), 0) - COALESCE(SUM(debit), 0) AS net_change
  FROM all_transactions;
END;
$$;

-- Grant execute permission
GRANT EXECUTE ON FUNCTION calculate_balance_between_dates(UUID, DATE, DATE) TO authenticated;
