/*
  # Fix Expense COA Accounts and Mapping V2
  
  1. Purpose
    - Create missing expense COA accounts (5200, 5300)
    - Add proper expense sub-categories    - Fix expense-to-COA mapping in trigger
    - Fix narrations to show actual expense descriptions
  
  2. Changes
    - Add Import Duty account (5200)
    - Add Import Freight account (5300)
    - Add more granular expense accounts
    - Update expense accounting trigger with better mapping
    - Fix narration to pull from expense description
  
  3. Impact
    - Expenses will map to correct accounts
    - Journal narrations will be descriptive
    - Better financial reporting
*/

-- Add missing COA accounts for better expense categorization
INSERT INTO chart_of_accounts (code, name, account_type, account_group, normal_balance, is_active) VALUES
('5200', 'Import Duties & Taxes', 'expense', 'COGS', 'debit', true),
('5300', 'Freight & Logistics', 'expense', 'COGS', 'debit', true),
('6150', 'Staff Benefits', 'expense', 'Operating Expenses', 'debit', true),
('6510', 'Delivery Expenses', 'expense', 'Operating Expenses', 'debit', true),
('6520', 'Loading & Unloading', 'expense', 'Operating Expenses', 'debit', true),
('6410', 'Office Administration', 'expense', 'Operating Expenses', 'debit', true),
('6420', 'Office Renovation & Shifting', 'expense', 'Operating Expenses', 'debit', true),
('6710', 'BPOM & SKI Fees', 'expense', 'Operating Expenses', 'debit', true)
ON CONFLICT (code) DO NOTHING;

-- Drop triggers first, then function
DROP TRIGGER IF EXISTS expense_auto_accounting_trigger ON finance_expenses;
DROP TRIGGER IF EXISTS trigger_auto_post_expense_accounting ON finance_expenses;
DROP FUNCTION IF EXISTS auto_post_expense_accounting() CASCADE;

-- Recreate function with better mapping and narration
CREATE OR REPLACE FUNCTION auto_post_expense_accounting()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_description TEXT;
  v_inventory_account_id UUID;
  v_expense_account_id UUID;
  v_cash_account_id UUID;
  v_petty_cash_account_id UUID;
  v_payment_account_id UUID;
  v_journal_id UUID;
  v_entry_type TEXT;
  v_pc_number TEXT;
  v_petty_cash_tx_id UUID;
  v_narration TEXT;
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

  -- Determine payment account based on payment_method
  IF NEW.payment_method = 'petty_cash' THEN
    v_payment_account_id := v_petty_cash_account_id;
  ELSE
    v_payment_account_id := v_cash_account_id;
  END IF;

  -- IMPROVED: Determine expense account based on category with better mapping
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
    WHEN NEW.expense_category IN ('office_shifting', 'office_renovation') THEN code = '6420'
    -- Transportation & Delivery
    WHEN NEW.expense_category IN ('delivery_sales', 'transport') THEN code = '6510'
    WHEN NEW.expense_category IN ('loading_sales', 'loading') THEN code = '6520'
    WHEN NEW.expense_category = 'transportation' THEN code = '6500'
    -- Marketing
    WHEN NEW.expense_category IN ('marketing', 'advertising') THEN code = '6600'
    -- Professional Fees
    WHEN NEW.expense_category IN ('professional_fees', 'legal', 'audit', 'consulting') THEN code = '6700'
    -- Default: Miscellaneous
    ELSE code = '6900'
  END
  LIMIT 1;

  -- IMPROVED: Build better narration from expense description
  IF NEW.description IS NOT NULL AND NEW.description != '' THEN
    v_narration := NEW.description;
  ELSE
    v_narration := NEW.expense_category;
  END IF;

  -- Build journal description
  v_description := 'Expense: ' || COALESCE(NEW.description, NEW.expense_category);

  -- Determine entry type
  IF NEW.import_container_id IS NOT NULL THEN
    v_entry_type := 'CAPITALIZED TO INVENTORY';
  ELSE
    v_entry_type := 'EXPENSED TO P&L';
  END IF;

  -- Create journal entry with ZERO totals (will be recalculated by trigger)
  IF NEW.import_container_id IS NOT NULL AND v_inventory_account_id IS NOT NULL THEN
    INSERT INTO journal_entries (
      entry_date, source_module, reference_id, reference_number,
      description, total_debit, total_credit, is_posted, created_by
    ) VALUES (
      NEW.expense_date, 'expenses', NEW.id, 'EXP-' || COALESCE(NEW.voucher_number, NEW.id::text),
      v_description || ' (' || v_entry_type || ')', 0, 0, true, NEW.created_by
    ) RETURNING id INTO v_journal_id;

    -- Insert lines (trigger will recalculate totals)
    INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit, description)
    VALUES
      (v_journal_id, v_inventory_account_id, NEW.amount, 0, v_narration),
      (v_journal_id, v_payment_account_id, 0, NEW.amount,
       CASE WHEN NEW.payment_method = 'petty_cash' THEN 'Petty Cash' ELSE 'Cash/Bank' END);

  ELSIF v_expense_account_id IS NOT NULL THEN
    INSERT INTO journal_entries (
      entry_date, source_module, reference_id, reference_number,
      description, total_debit, total_credit, is_posted, created_by
    ) VALUES (
      NEW.expense_date, 'expenses', NEW.id, 'EXP-' || COALESCE(NEW.voucher_number, NEW.id::text),
      v_description || ' (' || v_entry_type || ')', 0, 0, true, NEW.created_by
    ) RETURNING id INTO v_journal_id;

    -- Insert lines (trigger will recalculate totals)
    INSERT INTO journal_entry_lines (journal_entry_id, account_id, debit, credit, description)
    VALUES
      (v_journal_id, v_expense_account_id, NEW.amount, 0, v_narration),
      (v_journal_id, v_payment_account_id, 0, NEW.amount,
       CASE WHEN NEW.payment_method = 'petty_cash' THEN 'Petty Cash' ELSE 'Cash/Bank' END);
  END IF;

  -- Create petty cash transaction if needed AND store bidirectional link
  IF NEW.payment_method = 'petty_cash' AND v_journal_id IS NOT NULL THEN
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

    -- Store bidirectional link back to finance_expenses
    UPDATE finance_expenses
    SET petty_cash_transaction_id = v_petty_cash_tx_id
    WHERE id = NEW.id;
  END IF;

  RETURN NEW;
EXCEPTION
  WHEN OTHERS THEN
    RAISE NOTICE 'Error auto-posting expense accounting: %', SQLERRM;
    RETURN NEW;
END;
$$;

-- Recreate trigger
CREATE TRIGGER trigger_auto_post_expense_accounting
AFTER INSERT ON finance_expenses
FOR EACH ROW
EXECUTE FUNCTION auto_post_expense_accounting();

-- Update existing journal entries with better narrations (where description is generic)
UPDATE journal_entry_lines jel
SET description = COALESCE(fe.description, jel.description)
FROM journal_entries je
LEFT JOIN finance_expenses fe ON je.reference_id = fe.id AND je.source_module = 'expenses'
WHERE jel.journal_entry_id = je.id
  AND je.source_module = 'expenses'
  AND fe.description IS NOT NULL
  AND fe.description != ''
  AND jel.description LIKE 'Expense - %';

COMMENT ON FUNCTION auto_post_expense_accounting() IS 'Auto-posts expense transactions to journal with proper COA mapping and descriptive narrations';
