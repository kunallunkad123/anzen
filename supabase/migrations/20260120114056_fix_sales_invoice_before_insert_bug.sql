/*
  # Fix Sales Invoice Journal Entry Bug
  
  1. Critical Bug
    - The function does "UPDATE sales_invoices SET journal_entry_id = v_je_id WHERE id = NEW.id"
    - But this is a BEFORE INSERT trigger - the row doesn't exist yet!
    - This causes the UPDATE to fail silently
    - Should use "NEW.journal_entry_id := v_je_id" instead
  
  2. Fix
    - Change UPDATE statement to direct assignment
    - Match the pattern used in receipt_voucher function
*/

CREATE OR REPLACE FUNCTION post_sales_invoice_journal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_je_id UUID;
  v_je_number TEXT;
  v_ar_account_id UUID;
  v_sales_account_id UUID;
  v_ppn_account_id UUID;
  v_cogs_account_id UUID;
  v_inventory_account_id UUID;
  v_total_cogs DECIMAL(18,2) := 0;
  v_item_record RECORD;
  v_sales_amount DECIMAL(18,2);
  v_total_credit DECIMAL(18,2);
BEGIN
  -- Only post on insert or when payment_status changes to 'pending' or 'partial'
  IF TG_OP = 'INSERT' OR (TG_OP = 'UPDATE' AND OLD.journal_entry_id IS NULL AND NEW.payment_status IN ('pending', 'partial', 'paid')) THEN

    -- Get account IDs
    SELECT id INTO v_ar_account_id FROM chart_of_accounts WHERE code = '1120' LIMIT 1;
    SELECT id INTO v_sales_account_id FROM chart_of_accounts WHERE code = '4100' LIMIT 1;
    SELECT id INTO v_ppn_account_id FROM chart_of_accounts WHERE code = '2130' LIMIT 1;
    SELECT id INTO v_cogs_account_id FROM chart_of_accounts WHERE code = '5100' LIMIT 1;
    SELECT id INTO v_inventory_account_id FROM chart_of_accounts WHERE code = '1130' LIMIT 1;

    IF v_ar_account_id IS NULL OR v_sales_account_id IS NULL THEN
      RETURN NEW;
    END IF;

    -- ================================================
    -- ENTRY 1: REVENUE RECOGNITION (AR, Sales, PPN)
    -- ================================================

    -- Calculate sales amount after discount
    v_sales_amount := NEW.subtotal - COALESCE(NEW.discount_amount, 0);
    
    -- Calculate total credit (sales + tax)
    v_total_credit := v_sales_amount + COALESCE(NEW.tax_amount, 0);

    -- Generate journal entry number using COUNT method
    v_je_number := 'JE' || TO_CHAR(NEW.invoice_date, 'YYMM') || '-' || LPAD((
      SELECT COUNT(*) + 1 FROM journal_entries WHERE entry_number LIKE 'JE' || TO_CHAR(NEW.invoice_date, 'YYMM') || '%'
    )::TEXT, 4, '0');

    -- Create journal entry for revenue with CORRECT total_credit
    INSERT INTO journal_entries (
      entry_number, entry_date, source_module, reference_id, reference_number,
      description, total_debit, total_credit, is_posted, posted_by
    ) VALUES (
      v_je_number, NEW.invoice_date, 'sales_invoice', NEW.id, NEW.invoice_number,
      'Sales Invoice: ' || NEW.invoice_number, NEW.total_amount, v_total_credit, true, NEW.created_by
    ) RETURNING id INTO v_je_id;

    -- Dr: Accounts Receivable
    INSERT INTO journal_entry_lines (
      journal_entry_id, line_number, account_id, debit, credit, description, customer_id
    ) VALUES (
      v_je_id, 1, v_ar_account_id, NEW.total_amount, 0,
      'Invoice ' || NEW.invoice_number, NEW.customer_id
    );

    -- Cr: Sales Revenue (after discount)
    INSERT INTO journal_entry_lines (
      journal_entry_id, line_number, account_id, debit, credit, description
    ) VALUES (
      v_je_id, 2, v_sales_account_id, 0, v_sales_amount,
      'Sales Revenue - ' || NEW.invoice_number
    );

    -- Cr: PPN (Tax Payable) if any
    IF NEW.tax_amount > 0 AND v_ppn_account_id IS NOT NULL THEN
      INSERT INTO journal_entry_lines (
        journal_entry_id, line_number, account_id, debit, credit, description
      ) VALUES (
        v_je_id, 3, v_ppn_account_id, 0, NEW.tax_amount,
        'PPN 11% - ' || NEW.invoice_number
      );
    END IF;

    -- CRITICAL FIX: Use direct assignment instead of UPDATE (this is BEFORE INSERT trigger)
    NEW.journal_entry_id := v_je_id;

    -- ================================================
    -- ENTRY 2: COST OF GOODS SOLD (COGS & Inventory)
    -- ================================================

    IF v_cogs_account_id IS NOT NULL AND v_inventory_account_id IS NOT NULL THEN
      -- Calculate total COGS from invoice items
      FOR v_item_record IN
        SELECT 
          sii.product_id,
          sii.batch_id,
          sii.quantity,
          COALESCE(b.purchase_price, 0) as cost_per_unit,
          (sii.quantity * COALESCE(b.purchase_price, 0)) as total_cost
        FROM sales_invoice_items sii
        LEFT JOIN batches b ON b.id = sii.batch_id
        WHERE sii.invoice_id = NEW.id
      LOOP
        v_total_cogs := v_total_cogs + v_item_record.total_cost;
      END LOOP;

      -- Only post COGS entry if there's actual cost
      IF v_total_cogs > 0 THEN
        -- Generate new journal entry number for COGS
        v_je_number := 'JE' || TO_CHAR(NEW.invoice_date, 'YYMM') || '-' || LPAD((
          SELECT COUNT(*) + 1 FROM journal_entries WHERE entry_number LIKE 'JE' || TO_CHAR(NEW.invoice_date, 'YYMM') || '%'
        )::TEXT, 4, '0');

        -- Create journal entry for COGS
        INSERT INTO journal_entries (
          entry_number, entry_date, source_module, reference_id, reference_number,
          description, total_debit, total_credit, is_posted, posted_by
        ) VALUES (
          v_je_number, NEW.invoice_date, 'sales_invoice_cogs', NEW.id, NEW.invoice_number,
          'COGS for Sales Invoice: ' || NEW.invoice_number, v_total_cogs, v_total_cogs, true, NEW.created_by
        ) RETURNING id INTO v_je_id;

        -- Dr: COGS
        INSERT INTO journal_entry_lines (
          journal_entry_id, line_number, account_id, debit, credit, description, customer_id
        ) VALUES (
          v_je_id, 1, v_cogs_account_id, v_total_cogs, 0,
          'COGS - ' || NEW.invoice_number, NEW.customer_id
        );

        -- Cr: Inventory
        INSERT INTO journal_entry_lines (
          journal_entry_id, line_number, account_id, debit, credit, description
        ) VALUES (
          v_je_id, 2, v_inventory_account_id, 0, v_total_cogs,
          'Inventory Reduction - ' || NEW.invoice_number
        );
      END IF;
    END IF;

  END IF;

  RETURN NEW;
END;
$$;
