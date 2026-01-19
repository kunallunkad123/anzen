/*
  # Backfill All Missing Expense Journal Entries

  1. Problem
    - 197 out of 243 expenses have no journal entries
    - Journal not properly linked to expenses
    - Need proper entry numbers and line numbers

  2. Solution
    - Create journal entries for ALL expenses without them
    - Generate entry numbers based on expense date
    - Add line numbers to journal entry lines
    - Use correct payment accounts (bank/cash/petty cash/payable)
    - Use actual descriptions

  3. Security
    - No RLS changes needed
*/

-- Create journal entries for all expenses that don't have them
DO $$
DECLARE
  expense_rec RECORD;
  v_inventory_account_id UUID;
  v_expense_account_id UUID;
  v_cash_account_id UUID;
  v_petty_cash_account_id UUID;
  v_payable_account_id UUID;
  v_payment_account_id UUID;
  v_bank_coa_id UUID;
  v_journal_id UUID;
  v_narration TEXT;
  v_payment_description TEXT;
  v_bank_alias TEXT;
  v_entry_number TEXT;
  v_year TEXT;
  v_month TEXT;
  v_count INT := 0;
  v_total INT := 0;
BEGIN
  -- Get static account IDs
  SELECT id INTO v_inventory_account_id FROM chart_of_accounts WHERE code = '1130' LIMIT 1;
  SELECT id INTO v_cash_account_id FROM chart_of_accounts WHERE code = '1101' LIMIT 1;
  SELECT id INTO v_petty_cash_account_id FROM chart_of_accounts WHERE code = '1102' LIMIT 1;
  SELECT id INTO v_payable_account_id FROM chart_of_accounts WHERE code = '2100' LIMIT 1;

  RAISE NOTICE 'Starting backfill of missing expense journal entries...';
  
  -- Loop through all expenses without journal entries
  FOR expense_rec IN 
    SELECT fe.*
    FROM finance_expenses fe
    WHERE NOT EXISTS (
      SELECT 1 FROM journal_entries je 
      WHERE je.source_module = 'expenses' 
        AND je.reference_id = fe.id
    )
    ORDER BY fe.expense_date, fe.created_at
  LOOP
    -- Generate entry number based on expense date
    v_year := TO_CHAR(expense_rec.expense_date, 'YY');
    v_month := TO_CHAR(expense_rec.expense_date, 'MM');
    
    SELECT COALESCE(MAX(CAST(SUBSTRING(entry_number FROM '\d+$') AS INTEGER)), 0) + 1 INTO v_count
    FROM journal_entries
    WHERE entry_number LIKE 'JE' || v_year || v_month || '%';
    
    v_entry_number := 'JE' || v_year || v_month || '-' || LPAD(v_count::TEXT, 4, '0');

    -- Determine payment account
    IF expense_rec.payment_method IS NULL THEN
      v_payment_account_id := v_payable_account_id;
      v_payment_description := 'Accounts Payable (Unpaid)';
    ELSIF expense_rec.payment_method = 'petty_cash' THEN
      v_payment_account_id := v_petty_cash_account_id;
      v_payment_description := 'Petty Cash';
    ELSIF expense_rec.payment_method = 'bank_transfer' AND expense_rec.bank_account_id IS NOT NULL THEN
      SELECT ba.coa_id, COALESCE(ba.alias, ba.account_name)
      INTO v_bank_coa_id, v_bank_alias
      FROM bank_accounts ba
      WHERE ba.id = expense_rec.bank_account_id
      LIMIT 1;
      
      IF v_bank_coa_id IS NOT NULL THEN
        v_payment_account_id := v_bank_coa_id;
        v_payment_description := 'Bank: ' || COALESCE(v_bank_alias, 'Unknown');
      ELSE
        v_payment_account_id := v_cash_account_id;
        v_payment_description := 'Cash on Hand';
      END IF;
    ELSE
      v_payment_account_id := v_cash_account_id;
      v_payment_description := 'Cash on Hand';
    END IF;

    -- Determine expense account
    SELECT id INTO v_expense_account_id
    FROM chart_of_accounts
    WHERE CASE
      WHEN expense_rec.expense_category IN ('duty_customs', 'ppn_import', 'pph_import', 'duty') THEN code = '5200'
      WHEN expense_rec.expense_category IN ('freight_import', 'clearing_forwarding', 'freight') THEN code = '5300'
      WHEN expense_rec.expense_category IN ('container_handling', 'port_charges', 'transport_import', 'loading_import', 'other_import') THEN code = '5400'
      WHEN expense_rec.expense_category = 'bpom_ski_fees' THEN code = '6710'
      WHEN expense_rec.expense_category = 'salary' THEN code = '6100'
      WHEN expense_rec.expense_category IN ('staff_benefits', 'staff_welfare') THEN code = '6150'
      WHEN expense_rec.expense_category = 'warehouse_rent' THEN code = '6210'
      WHEN expense_rec.expense_category = 'office_rent' THEN code = '6220'
      WHEN expense_rec.expense_category = 'utilities' THEN code = '6300'
      WHEN expense_rec.expense_category IN ('office_admin', 'office_supplies') THEN code = '6410'
      WHEN expense_rec.expense_category IN ('office_shifting', 'office_renovation', 'office_shifting_renovation') THEN code = '6420'
      WHEN expense_rec.expense_category IN ('delivery_sales', 'transport') THEN code = '6510'
      WHEN expense_rec.expense_category IN ('loading_sales', 'loading') THEN code = '6520'
      WHEN expense_rec.expense_category IN ('transportation', 'travel_conveyance') THEN code = '6500'
      WHEN expense_rec.expense_category = 'bank_charges' THEN code = '6800'
      WHEN expense_rec.expense_category IN ('marketing', 'advertising') THEN code = '6600'
      WHEN expense_rec.expense_category IN ('professional_fees', 'legal', 'audit', 'consulting') THEN code = '6700'
      ELSE code = '6900'
    END
    LIMIT 1;

    -- Build narration
    IF expense_rec.description IS NOT NULL AND expense_rec.description != '' THEN
      v_narration := expense_rec.description;
    ELSE
      v_narration := 'Expense: ' || expense_rec.expense_category;
    END IF;

    -- Create journal entry
    IF expense_rec.import_container_id IS NOT NULL AND v_inventory_account_id IS NOT NULL THEN
      -- Capitalized to inventory
      INSERT INTO journal_entries (
        entry_number, entry_date, source_module, reference_id, reference_number,
        description, total_debit, total_credit, is_posted, created_by
      ) VALUES (
        v_entry_number, expense_rec.expense_date, 'expenses', expense_rec.id, 
        'EXP-' || COALESCE(expense_rec.voucher_number, expense_rec.id::text),
        'Expense: ' || COALESCE(expense_rec.description, expense_rec.expense_category) || ' (CAPITALIZED TO INVENTORY)', 
        0, 0, true, expense_rec.created_by
      ) RETURNING id INTO v_journal_id;

      INSERT INTO journal_entry_lines (journal_entry_id, line_number, account_id, debit, credit, description)
      VALUES
        (v_journal_id, 1, v_inventory_account_id, expense_rec.amount, 0, v_narration),
        (v_journal_id, 2, v_payment_account_id, 0, expense_rec.amount, v_payment_description);

    ELSIF v_expense_account_id IS NOT NULL THEN
      -- Expensed to P&L
      INSERT INTO journal_entries (
        entry_number, entry_date, source_module, reference_id, reference_number,
        description, total_debit, total_credit, is_posted, created_by
      ) VALUES (
        v_entry_number, expense_rec.expense_date, 'expenses', expense_rec.id, 
        'EXP-' || COALESCE(expense_rec.voucher_number, expense_rec.id::text),
        'Expense: ' || COALESCE(expense_rec.description, expense_rec.expense_category) || ' (EXPENSED TO P&L)', 
        0, 0, true, expense_rec.created_by
      ) RETURNING id INTO v_journal_id;

      INSERT INTO journal_entry_lines (journal_entry_id, line_number, account_id, debit, credit, description)
      VALUES
        (v_journal_id, 1, v_expense_account_id, expense_rec.amount, 0, v_narration),
        (v_journal_id, 2, v_payment_account_id, 0, expense_rec.amount, v_payment_description);
    END IF;

    v_total := v_total + 1;
    
    IF v_total % 50 = 0 THEN
      RAISE NOTICE 'Created % journal entries...', v_total;
    END IF;
  END LOOP;
  
  RAISE NOTICE 'Backfill complete! Created % new journal entries for expenses', v_total;
END $$;
