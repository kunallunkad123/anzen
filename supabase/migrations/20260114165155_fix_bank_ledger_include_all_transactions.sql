/*
  # Fix Bank Ledger - Include All Transaction Types

  1. Problem
    - Bank ledger was missing fund transfers and petty cash transactions
    - This caused incorrect opening balance calculations when filtering by date
    - Balance would go negative unexpectedly

  2. Solution
    - Update calculate_balance_between_dates function to include:
      - Fund transfers (both from_account and to_account)
      - Petty cash replenishments from bank
      - Petty cash deposits to bank

  3. Logic
    - Fund transfer FROM this account = debit (money out)
    - Fund transfer TO this account = credit (money in)
    - Petty cash FROM bank = debit (money out)
    - Petty cash TO bank = credit (money in)
*/

-- Drop the old function
DROP FUNCTION IF EXISTS calculate_balance_between_dates(UUID, DATE, DATE);

-- Create updated function with ALL transaction types
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
    WHERE from_account_id = p_bank_account_id
      AND transfer_date >= p_start_date
      AND transfer_date < p_end_date

    UNION ALL

    -- Fund transfers TO this account (money IN)
    SELECT
      to_amount AS credit,
      0 AS debit
    FROM fund_transfers
    WHERE to_account_id = p_bank_account_id
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
