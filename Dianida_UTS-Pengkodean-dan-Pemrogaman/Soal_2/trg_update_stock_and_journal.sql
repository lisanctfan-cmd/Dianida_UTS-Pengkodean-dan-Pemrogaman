CREATE OR REPLACE FUNCTION trg_update_stock_and_journal()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_stock_qty INT;
BEGIN
    -- Mengunci dan membaca stok barang
    SELECT stock_qty
    INTO v_stock_qty
    FROM inventory_items
    WHERE item_id = NEW.item_id
    FOR UPDATE;

    -- Memeriksa keberadaan barang
    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Barang dengan ID % tidak ditemukan',
            NEW.item_id;
    END IF;

    -- Memvalidasi jumlah transaksi
    IF NEW.qty IS NULL OR NEW.qty <= 0 THEN
        RAISE EXCEPTION
            'Jumlah transaksi harus lebih besar dari nol';
    END IF;

    -- Poin a: Memperbarui stok secara otomatis
    IF NEW.trx_type = 'PURCHASE' THEN
        UPDATE inventory_items
        SET stock_qty = stock_qty + NEW.qty
        WHERE item_id = NEW.item_id;

    ELSIF NEW.trx_type = 'SALE' THEN

        -- Poin b: Mencegah stok menjadi negatif
        IF v_stock_qty - NEW.qty < 0 THEN
            RAISE EXCEPTION
                'Stok tidak mencukupi. Stok tersedia: %, jumlah penjualan: %',
                v_stock_qty, NEW.qty;
        END IF;

        UPDATE inventory_items
        SET stock_qty = stock_qty - NEW.qty
        WHERE item_id = NEW.item_id;

    ELSIF NEW.trx_type = 'ADJUSTMENT' THEN

        -- qty positif menambah stok
        IF v_stock_qty + NEW.qty < 0 THEN
            RAISE EXCEPTION
                'Penyesuaian stok tidak boleh menghasilkan stok negatif';
        END IF;

        UPDATE inventory_items
        SET stock_qty = stock_qty + NEW.qty
        WHERE item_id = NEW.item_id;

    ELSE
        RAISE EXCEPTION
            'Jenis transaksi tidak valid: %',
            NEW.trx_type;
    END IF;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_inventory_stock
BEFORE INSERT ON inventory_transactions
FOR EACH ROW
EXECUTE FUNCTION trg_update_stock_and_journal();