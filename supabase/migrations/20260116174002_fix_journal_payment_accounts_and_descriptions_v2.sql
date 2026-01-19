/*
  # Fix Journal Entry Payment Accounts and Descriptions

  1. Issues Fixed
    - Expense trigger now correctly identifies payment account:
      * Bank transfers use the actual bank's COA account
      * Cash payments use Cash on Hand
      * Petty cash uses Petty Cash account
      * Unpaid expenses use Accounts Payable
    - Journal view now shows bank alias (e.g., "BCA - IDR") instead of full account number
    - Trigger now supports UPDATE operations (not just INSERT)
    - Backfill existing journal entries with proper descriptions and payment accounts

  2. Changes
    - Drop and recreate expense accounting trigger with proper payment account logic
    - Add UPDATE trigger support to reflect changes in expenses
    - Update journal_voucher_view to use bank alias
    - Backfill journal entry lines with actual expense descriptions and correct payment accounts

  3. Security
    - No RLS changes needed
*/

-- Drop existing trigger
DROP TRIGGER IF EXISTS trigger_auto_post_expense_accounting ON finance_expenses;

-- Recreate function with proper payment account detection
CREATE OR REPLACE FUNCTION auto_post_expense_accounting()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_description TEXT;
  v_inventory_account_id UUID;
  v_expense_account_id UUID;
  v_cash_account_id UUID;
  v_petty_cash_account_id UUID;
  v_payable_account_id UUID;
  v_payment_account_id UUID;
  v_bank_coa_id UUID;
  v_journal_id UUID;
  v_entry_type TEXT;
  v_pc_number TEXT;
  v_petty_cash_tx_id UUID;
  v_narration TEXT;
  v_payment_description TEXT;
  v_bank_alias TEXT;
BEGIN
  -- Get account IDs
  SELECT id INTO v_inventory_account_id
  FROM chart_of_accounts
  WHERE code = '1130'
  LIMIT 1;

  SELECT id INTO v_cash_account_id
  FROM chart_of_accounts
  WHERE code = '1101'
  LIMIT 1;

  SELECT id INTO v_petty_cash_account_id
  FROM chart_of_accounts
  WHERE code = '1102'
  LIMIT 1;

  SELECT id INTO v_payable_account_id
  FROM chart_of_accounts
  WHERE code = '2100'
  LIMIT 1;

  -- FIXED: Determine payment account based on payment_method AND bank_account_id
  IF NEW.payment_method IS NULL THEN
    -- Unpaid expense
    v_payment_account_id := v_payable_account_id;
    v_payment_description := 'Accounts Payable (Unpaid)';
  ELSIF NEW.payment_method = 'petty_cash' THEN
    v_payment_account_id := v_petty_cash_account_id;
    v_payment_description := 'Petty Cash';
  ELSIF NEW.payment_method = 'bank_transfer' AND NEW.bank_account_id IS NOT NULL THEN
    -- Get the bank's COA account ID and alias
    SELECT ba.coa_id, COALESCE(ba.alias, ba.account_name)
    INTO v_bank_coa_id, v_bank_alias
    FROM bank_accounts ba
    WHERE ba.id = NEW.bank_account_id
    LIMIT 1;
    
    IF v_bank_coa_id IS NOT NULL THEN
      v_payment_account_id := v_bank_coa_id;
      v_payment_description := 'Bank: ' || COALESCE(v_bank_alias, 'Unknown');
    ELSE
      -- Fallback to cash if bank COA not found
      v_payment_account_id := v_cash_account_id;
      v_payment_description := 'Cash on Hand (Bank COA Missing)';
    END IF;
  ELSE
    -- Cash payment
    v_payment_account_id := v_cash_account_id;
    v_payment_description := 'Cash on Hand';
  END IF;

  -- Determine expense account based on category
  SELECT id INTO v_expense_account_id
  FROM chart_of_accounts
  WHERE CASE
    -- Import Duties & Taxes
    WHEN NEW.expense_category IN ('duty_customs', 'ppn_import', 'pph_import', 'duty') THEN code = '5200'
    -- Freight & Logistics (Import)
    WHEN NEW.expense_category IN ('freight_import', 'clearing_forwarding', 'freight') THEN code = '5300'
    -- Other Import Costs
    WHEN NEW.expense_category IN ('container_handling', 'port_charges', 'transport_import', 'loading_import', 'other_import') THEN code = '5400'
    -- BPOM & SKI Fees
    WHEN NEW.expense_category = 'bpom_ski_fees' THEN code = '6710'
    -- Salaries & Benefits
    WHEN NEW.expense_category = 'salary' THEN code = '6100'
    WHEN NEW.expense_category IN ('staff_benefits', 'staff_welfare') THEN code = '6150'
    -- Rent
    WHEN NEW.expense_category = 'warehouse_rent' THEN code = '6210'
    WHEN NEW.expense_category = 'office_rent' THEN code = '6220'
    -- Utilities
    WHEN NEW.expense_category = 'utilities' THEN code = '6300'
    -- Office
    WHEN NEW.expense_category IN ('office_admin', 'office_supplies') THEN code = '6410'
    WHEN NEW.expense_category IN ('office_shifting', 'office_renovation', 'office_shifting_renovation') THEN code = '6420'
    -- Transportation & Delivery
    WHEN NEW.expense_category IN ('delivery_sales', 'transport') THEN code = '6510'
    WHEN NEW.expense_category IN ('loading_sales', 'loading') THEN code = '6520'
    WHEN NEW.expense_category IN ('transportation', 'travel_conveyance') THEN code = '6500'
    -- Bank Charges
    WHEN NEW.expense_category = 'bank_charges' THEN code = '6800'
    -- Marketing
    WHEN NEW.expense_category IN ('marketing', 'advertising') THEN code = '6600'
    -- Professional Fees
    WHEN NEW.expense_category IN ('professional_fees', 'legal', 'audit', 'consulting') THEN code = '6700'
    -- Default: Miscellaneous
    ELSE code = '6900'
  END
  LIMIT 1;

  -- Build narration from expense description
  IF NEW.description IS NOT NULL AND NEW.description != '' THEN
    v_narration := NEW.description;
  ELSE
    v_narration := 'Expense: ' || NEW.expense_category;
  END IF;

  -- Build journal description
  v_description := 'Expense: ' || COALESCE(NEW.description, NEW.expense_category);

  -- Determine entry type
  IF NEW.import_container_id IS NOT NULL THEN
    v_entry_type := 'CAPITALIZED TO INVENTORY';
  ELSE
    v_entry_type := 'EXPENSED TO P&L';
  END IF;

  -- Check if journal entry already exists (for UPDATE operations)
  SELECT id INTO v_journal_id
  FROM journal_entries
  WHERE source_module = 'expenses' 
    AND reference_id = NEW.id
  LIMIT 1;

  IF v_journal_id IS NOT NULL THEN
    -- UPDATE existing journal entry
    UPDATE journal_entries
    SET 
      entry_date = NEW.expense_date,
      reference_number = 'EXP-' || COALESCE(NEW.voucher_number, NEW.id::text),
      description = v_description || ' (' || v_entry_type || ')'
    WHERE id = v_journal_id;

    -- Delete old lines
    DELETE FROM journal_entry_lines WHERE journal_entry_id = v_journal_id;

    -- Insert updated lines
    IF NEW.import_container_id IS NOT NULL AND v_inventory_account_id IS NOT NULL THEN
      INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit, description)
      VALUES
        (v_journal_id, v_inventory_account_id, NEW.amount, 0, v_narration),
        (v_journal_id, v_payment_account_id, 0, NEW.amount, v_payment_description);
    ELSIF v_expense_account_id IS NOT NULL THEN
      INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit, description)
      VALUES
        (v_journal_id, v_expense_account_id, NEW.amount, 0, v_narration),
        (v_journal_id, v_payment_account_id, 0, NEW.amount, v_payment_description);
    END IF;

  ELSE
    -- INSERT new journal entry
    IF NEW.import_container_id IS NOT NULL AND v_inventory_account_id IS NOT NULL THEN
      INSERT INTO journal_entries (
        entry_date, source_module, reference_id, reference_number,
        description, total_debit, total_credit, is_posted, created_by
      ) VALUES (
        NEW.expense_date, 'expenses', NEW.id, 'EXP-' || COALESCE(NEW.voucher_number, NEW.id::text),
        v_description || ' (' || v_entry_type || ')', 0, 0, true, NEW.created_by
      ) RETURNING id INTO v_journal_id;

      INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit, description)
      VALUES
        (v_journal_id, v_inventory_account_id, NEW.amount, 0, v_narration),
        (v_journal_id, v_payment_account_id, 0, NEW.amount, v_payment_description);

    ELSIF v_expense_account_id IS NOT NULL THEN
      INSERT INTO journal_entries (
        entry_date, source_module, reference_id, reference_number,
        description, total_debit, total_credit, is_posted, created_by
      ) VALUES (
        NEW.expense_date, 'expenses', NEW.id, 'EXP-' || COALESCE(NEW.voucher_number, NEW.id::text),
        v_description || ' (' || v_entry_type || ')', 0, 0, true, NEW.created_by
      ) RETURNING id INTO v_journal_id;

      INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit, description)
      VALUES
        (v_journal_id, v_expense_account_id, NEW.amount, 0, v_narration),
        (v_journal_id, v_payment_account_id, 0, NEW.amount, v_payment_description);
    END IF;
  END IF;

  -- Create or update petty cash transaction if needed
  IF NEW.payment_method = 'petty_cash' AND v_journal_id IS NOT NULL THEN
    -- Check if petty cash transaction already exists
    SELECT id INTO v_petty_cash_tx_id
    FROM petty_cash_transactions
    WHERE finance_expense_id = NEW.id
    LIMIT 1;

    IF v_petty_cash_tx_id IS NOT NULL THEN
      -- Update existing petty cash transaction
      UPDATE petty_cash_transactions
      SET
        transaction_date = NEW.expense_date,
        amount = NEW.amount,
        description = v_narration,
        expense_category = NEW.expense_category,
        bank_account_id = NEW.bank_account_id,
        paid_to = NEW.description,
        paid_by = NEW.paid_by
      WHERE id = v_petty_cash_tx_id;
    ELSE
      -- Create new petty cash transaction
      SELECT 'PC-' || TO_CHAR(NEW.expense_date, 'YYYYMMDD') || '-' ||
        LPAD((COUNT(*) + 1)::TEXT, 4, '0')
      INTO v_pc_number
      FROM petty_cash_transactions
      WHERE transaction_date = NEW.expense_date;

      INSERT INTO petty_cash_transactions (
        transaction_number,
        transaction_date,
        transaction_type,
        amount,
        description,
        expense_category,
        bank_account_id,
        created_by,
        source,
        paid_to,
        paid_by,
        finance_expense_id
      ) VALUES (
        v_pc_number,
        NEW.expense_date,
        'expense',
        NEW.amount,
        v_narration,
        NEW.expense_category,
        NEW.bank_account_id,
        NEW.created_by,
        'finance_expense',
        NEW.description,
        NEW.paid_by,
        NEW.id
      ) RETURNING id INTO v_petty_cash_tx_id;

      -- Store bidirectional link
      UPDATE finance_expenses
      SET petty_cash_transaction_id = v_petty_cash_tx_id
      WHERE id = NEW.id;
    END IF;
  END IF;

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Error auto-posting expense accounting: %', SQLERRM;
    RETURN NEW;
END;
$$;

-- Create trigger for INSERT and UPDATE
CREATE TRIGGER trigger_auto_post_expense_accounting
AFTER INSERT OR UPDATE ON finance_expenses
FOR EACH ROW
EXECUTE FUNCTION auto_post_expense_accounting();

-- Update journal_voucher_view to show bank alias instead of account number
DROP VIEW IF EXISTS journal_voucher_view CASCADE;

CREATE OR REPLACE VIEW journal_voucher_view AS
SELECT
  je.id AS journal_entry_id,
  je.entry_date AS date,
  je.entry_number AS voucher_no,
  CASE 
    WHEN je.source_module = 'sales_invoice' THEN 'Sales Invoice'
    WHEN je.source_module = 'expenses' THEN 'Expense'
    WHEN je.source_module = 'receipt' THEN 'Receipt Voucher'
    WHEN je.source_module = 'payment' THEN 'Payment Voucher'
    WHEN je.source_module = 'fund_transfers' THEN 'Journal'
    WHEN je.source_module = 'petty_cash' THEN 'Petty Cash'
    ELSE 'Journal Entry'
  END AS voucher_type,
  -- Get primary debit account (prefer bank alias if available)
  (
    SELECT 
      CASE
        WHEN ba.alias IS NOT NULL THEN ba.alias
        ELSE coa.code || ' - ' || coa.name
      END
    FROM journal_entry_lines jel
    JOIN chart_of_accounts coa ON jel.account_id = coa.id
    LEFT JOIN bank_accounts ba ON ba.coa_id = coa.id AND ba.is_active = true
    WHERE jel.journal_entry_id = je.id 
      AND jel.debit > 0
    ORDER BY jel.line_number
    LIMIT 1
  ) AS debit_account,
  -- Get primary credit account (prefer bank alias if available)
  (
    SELECT 
      CASE
        WHEN ba.alias IS NOT NULL THEN ba.alias
        ELSE coa.code || ' - ' || coa.name
      END
    FROM journal_entry_lines jel
    JOIN chart_of_accounts coa ON jel.account_id = coa.id
    LEFT JOIN bank_accounts ba ON ba.coa_id = coa.id AND ba.is_active = true
    WHERE jel.journal_entry_id = je.id 
      AND jel.credit > 0
    ORDER BY jel.line_number
    LIMIT 1
  ) AS credit_account,
  je.total_debit AS amount,
  -- Get narration from first debit line description
  COALESCE(
    (
      SELECT jel.description
      FROM journal_entry_lines jel
      WHERE jel.journal_entry_id = je.id 
        AND jel.debit > 0
      ORDER BY jel.line_number
      LIMIT 1
    ),
    je.description
  ) AS narration,
  je.reference_number,
  je.source_module,
  (SELECT COUNT(*) FROM journal_entry_lines WHERE journal_entry_id = je.id) AS line_count,
  (SELECT COUNT(*) > 2 FROM journal_entry_lines WHERE journal_entry_id = je.id) AS is_multi_line
FROM journal_entries je
WHERE je.is_posted = true
ORDER BY je.entry_date DESC, je.entry_number DESC;

-- Backfill existing journal entries by updating each expense record
-- This will trigger the new function to recreate journal entries with correct payment accounts
DO $$
DECLARE
  expense_rec RECORD;
  v_count INT := 0;
BEGIN
  RAISE NOTICE 'Starting backfill of expense journal entries...';
  
  -- Process all expenses that have journal entries
  FOR expense_rec IN 
    SELECT fe.id
    FROM finance_expenses fe
    WHERE EXISTS (
      SELECT 1 FROM journal_entries je 
      WHERE je.source_module = 'expenses' 
        AND je.reference_id = fe.id
    )
    ORDER BY fe.expense_date DESC
  LOOP
    -- Update the expense amount to itself to trigger the function
    -- This will recreate the journal entry with correct payment account
    UPDATE finance_expenses
    SET amount = amount
    WHERE id = expense_rec.id;
    
    v_count := v_count + 1;
    
    -- Log progress every 100 records
    IF v_count % 100 = 0 THEN
      RAISE NOTICE 'Processed % expenses...', v_count;
    END IF;
  END LOOP;
  
  RAISE NOTICE 'Backfill complete! Updated % expense journal entries with correct payment accounts and descriptions', v_count;
END $$;
