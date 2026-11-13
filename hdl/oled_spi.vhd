--------------------------------------------------------------------------------
-- hdl/oled_spi.vhd
-- Modul Daun Pengendali Display OLED SPI 128x64 SSD1306 (Milestone 4)
--
-- Karakteristik Arsitektur:
-- 1. Antarmuka SPI Mode 0 (CPOL=0, CPHA=0):
--    - SCLK diam rendah (LOW).
--    - Data MOSI (SDIN) berubah saat SCLK LOW, dicuplik pada tepi naik SCLK.
--    - Urutan transmisi bit: MSB duluan (bit 7 downto 0).
--    - Clock pembagi biner genap: f_SCLK = 100 MHz / CLK_DIV (default 16 -> 6,25 MHz).
--
-- 2. Urutan Power-On & Reset:
--    - Pulsa reset hardware oled_res aktif LOW selama RES_LOW_CYCLES (1.000 = 10 us).
--    - Jeda stabilisasi pasca-reset selama RES_WAIT_CYCLES (100.000 = 1 ms, DIASUMSIKAN).
--    - Urutan inisialisasi deterministik (25 byte perintah konfigurasi).
--    - oled_dc = '0' untuk perintah, oled_dc = '1' untuk data GDRAM.
--    - Sinyal oled_dc stabil sebelum CS assert dan ditahan setelah CS de-assert.
--
-- 3. Transposisi Citra On-The-Fly:
--    - Format sumber raster kanonik 128x64 (16 byte per baris, 64 baris).
--    - Format target GDRAM SSD1306: 8 Page vertikal (tinggi 8 baris per page, 128 kolom).
--    - Optimasi: membaca blok 8 byte BRAM per 8 kolom (k = 0..15), lalu mentransposisi
--      ke dalam 8 byte kolom vertikal (bit 0 = baris teratas page, bit 7 = baris terbawah).
--    - Tiap frame: kirim batas jendela kolom/halaman (0x21 00 7F, 0x22 00 07),
--      lalu semburkan tepat 1.024 byte data kontigu (Page 0..7 berurutan).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity oled_spi is
    generic (
        CLK_DIV         : natural := 16;                                      -- Pembagi clock: 100 MHz / CLK_DIV (default 16 -> 6,25 MHz)
        REMAP_SEG       : std_logic_vector(7 downto 0) := x"A1";              -- A0h (normal) / A1h (remap)
        REMAP_COM       : std_logic_vector(7 downto 0) := x"C8";              -- C0h (normal) / C8h (remap)
        CONTRAST        : std_logic_vector(7 downto 0) := x"CF";              -- Nilai kontras 00h .. FFh
        INVERT_DATA     : boolean := false;                                   -- false: data 1=piksel menyala; true: diinversi
        READ_LATENCY    : natural := 1;                                       -- Latensi pembacaan BRAM frame_buffer (1 siklus)
        RES_LOW_CYCLES  : natural := 1_000;                                   -- Lebar pulsa reset LOW (10 us pada 100 MHz; tRES >= 3 us)
        RES_WAIT_CYCLES : natural := 100_000;                                 -- Waktu tunggu pasca-reset (1 ms pada 100 MHz; DIASUMSIKAN)
        CS_SETUP_CYCLES : natural := 3;                                       -- Setup CS sebelum tepi SCLK (>= 3 siklus = 30 ns, tCSS >= 20 ns)
        CS_HOLD_CYCLES  : natural := 2                                        -- Hold CS setelah SCLK terakhir (>= 2 siklus = 20 ns, tCSH >= 10 ns)
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        start     : in  std_logic;                                            -- Pulsa stroba mulai kirim satu frame
        busy      : out std_logic;                                            -- Aktif '1' saat inisialisasi atau transfer frame
        rd_addr   : out std_logic_vector(9 downto 0);                         -- Alamat baca 10-bit ke frame_buffer (0..1023)
        rd_data   : in  std_logic_vector(7 downto 0);                         -- Data raster 8-bit dari frame_buffer
        oled_res  : out std_logic;                                            -- Sinyal Reset fisik OLED (aktif LOW)
        oled_dc   : out std_logic;                                            -- Data/Command ('0'=Command, '1'=Data)
        oled_cs   : out std_logic;                                            -- Chip Select (aktif LOW)
        oled_sclk : out std_logic;                                            -- SPI Serial Clock (Mode 0)
        oled_mosi : out std_logic;                                            -- SPI Master Out Slave In / SDIN
        init_done : out std_logic                                             -- Aktif '1' setelah urutan inisialisasi selesai
    );
end entity oled_spi;

architecture rtl of oled_spi is

    -- Tabel Perintah Inisialisasi Register SSD1306 (25 Byte)
    type cmd_array_t is array (0 to 24) of std_logic_vector(7 downto 0);
    constant INIT_CMDS : cmd_array_t := (
        x"AE",        -- 0: Display OFF (Sleep Mode)
        x"D5", x"80", -- 1,2: Set Display Clock Divide Ratio & Osc Freq (0x80 = nilai bawaan)
        x"A8", x"3F", -- 3,4: Set Multiplex Ratio (64MUX)
        x"D3", x"00", -- 5,6: Set Display Offset (Offset 0)
        x"40",        -- 7: Set Display Start Line (Line 0)
        x"8D", x"14", -- 8,9: Charge Pump Setting (Enable 7,5V; BELUM TERVERIFIKASI di Rev 1.1)
        x"20", x"00", -- 10,11: Set Memory Addressing Mode (Horizontal; BELUM TERVERIFIKASI di Rev 1.1)
        REMAP_SEG,    -- 12: Set Segment Re-map (A0h / A1h)
        REMAP_COM,    -- 13: Set COM Output Scan Direction (C0h / C8h)
        x"DA", x"12", -- 14,15: Set COM Pins Hardware Configuration (Alternative, Disable L/R)
        x"81", CONTRAST, -- 16,17: Set Contrast Control
        x"D9", x"F1", -- 18,19: Set Pre-charge Period (Phase 1 = 1 DCLK, Phase 2 = 15 DCLK)
        x"DB", x"20", -- 20,21: Set VCOMH Deselect Level (~0,77 x VCC)
        x"A4",        -- 22: Entire Display ON (Resume to RAM)
        x"A6",        -- 23: Set Normal Display (1 = piksel menyala)
        x"AF"         -- 24: Display ON (Normal Mode)
    );

    -- Perintah Pembatas Jendela Frame (6 Byte)
    type frame_cmd_t is array (0 to 5) of std_logic_vector(7 downto 0);
    constant FRAME_CMDS : frame_cmd_t := (
        x"21", x"00", x"7F", -- Set Column Address (0..127)
        x"22", x"00", x"07"  -- Set Page Address (0..7)
    );

    -- State FSM Utama
    type state_t is (
        ST_RESET_LOW,
        ST_RESET_WAIT,
        ST_INIT_BYTE_SETUP,
        ST_INIT_SPI_TX,
        ST_IDLE,
        ST_FRAME_CMD_SETUP,
        ST_FRAME_CMD_SPI_TX,
        ST_FETCH_BRAM_ADDR,
        ST_FETCH_BRAM_WAIT,
        ST_FETCH_BRAM_LATCH,
        ST_TRANSPOSE_BLOCK,
        ST_DATA_BYTE_SETUP,
        ST_DATA_SPI_TX,
        ST_FRAME_BURST_END
    );
    signal state : state_t := ST_RESET_LOW;

    -- State Serializer SPI Mode 0
    type spi_state_t is (
        SPI_IDLE,
        SPI_SETUP_CS,
        SPI_CLK_LOW,
        SPI_CLK_HIGH,
        SPI_HOLD_CS,
        SPI_DONE
    );
    signal spi_state : spi_state_t := SPI_IDLE;

    -- Register Kendali SPI
    signal spi_tx_byte   : std_logic_vector(7 downto 0) := (others => '0');
    signal spi_tx_start  : std_logic := '0';
    signal spi_tx_done   : std_logic := '0';
    signal spi_keep_cs   : std_logic := '0'; -- '1' jika CS dipertahankan LOW untuk byte berikutnya
    signal spi_div_cnt   : natural range 0 to 255 := 0;
    signal spi_bit_idx   : integer range 0 to 7 := 7;
    signal spi_setup_cnt : natural range 0 to 31 := 0;
    signal spi_hold_cnt  : natural range 0 to 31 := 0;

    -- Register Status & Output Fisik
    signal reg_busy      : std_logic := '1';
    signal reg_init_done : std_logic := '0';
    signal reg_oled_res  : std_logic := '0';
    signal reg_oled_dc   : std_logic := '0';
    signal reg_oled_cs   : std_logic := '1';
    signal reg_oled_sclk : std_logic := '0';
    signal reg_oled_mosi : std_logic := '0';

    -- Pencacah Siklus Waktu
    signal cycle_cnt : natural := 0;

    -- Indeks Transfer Inisialisasi & Frame
    signal init_idx  : integer range 0 to 24 := 0;
    signal cmd_idx   : integer range 0 to 5 := 0;
    signal page_idx  : integer range 0 to 7 := 0;
    signal block_idx : integer range 0 to 15 := 0;
    signal fetch_row : integer range 0 to 7 := 0;
    signal data_col  : integer range 0 to 7 := 0;
    signal wait_cnt  : natural range 0 to 15 := 0;

    -- Buffer Blok Pembacaan BRAM & Transposisi
    type tile_arr_t is array (0 to 7) of std_logic_vector(7 downto 0);
    signal tile_buf  : tile_arr_t := (others => (others => '0'));
    signal col_bytes : tile_arr_t := (others => (others => '0'));

    -- Konstanta setengah pembagi clock
    constant HALF_DIV : natural := CLK_DIV / 2;

begin

    -- Hubungkan sinyal keluaran
    busy      <= reg_busy;
    init_done <= reg_init_done;
    oled_res  <= reg_oled_res;
    oled_dc   <= reg_oled_dc;
    oled_cs   <= reg_oled_cs;
    oled_sclk <= reg_oled_sclk;
    oled_mosi <= reg_oled_mosi;

    -- -------------------------------------------------------------------------
    -- PROSES SERIALIZER SPI MODE 0 (Sub-FSM Sinkron 100 MHz)
    -- -------------------------------------------------------------------------
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                spi_state     <= SPI_IDLE;
                spi_tx_done   <= '0';
                spi_div_cnt   <= 0;
                spi_bit_idx   <= 7;
                spi_setup_cnt <= 0;
                spi_hold_cnt  <= 0;
                reg_oled_cs   <= '1';
                reg_oled_sclk <= '0';
                reg_oled_mosi <= '0';
            else
                case spi_state is
                    when SPI_IDLE =>
                        spi_tx_done   <= '0';
                        spi_div_cnt   <= 0;
                        spi_bit_idx   <= 7;
                        spi_setup_cnt <= 0;
                        spi_hold_cnt  <= 0;
                        reg_oled_sclk <= '0';

                        if spi_tx_start = '1' then
                            if reg_oled_cs = '1' then
                                -- CS masih HIGH: lakukan asersi CS LOW dan hitung setup time
                                reg_oled_cs   <= '0';
                                reg_oled_mosi <= spi_tx_byte(7);
                                spi_state     <= SPI_SETUP_CS;
                            else
                                -- CS sudah LOW (burst transfer): langsung siapkan bit 7 dan masuki fase SCLK LOW
                                reg_oled_mosi <= spi_tx_byte(7);
                                spi_state     <= SPI_CLK_LOW;
                            end if;
                        end if;

                    when SPI_SETUP_CS =>
                        -- Pertahankan CS LOW minimal CS_SETUP_CYCLES sebelum tepi naik SCLK pertama
                        reg_oled_mosi <= spi_tx_byte(7);
                        if spi_setup_cnt + 1 < CS_SETUP_CYCLES then
                            spi_setup_cnt <= spi_setup_cnt + 1;
                        else
                            spi_setup_cnt <= 0;
                            spi_div_cnt   <= 0;
                            reg_oled_sclk <= '1'; -- Tepi naik pertama tepat setelah CS setup
                            spi_state     <= SPI_CLK_HIGH;
                        end if;

                    when SPI_CLK_LOW =>
                        reg_oled_sclk <= '0';
                        reg_oled_mosi <= spi_tx_byte(spi_bit_idx);
                        if spi_div_cnt + 1 < HALF_DIV then
                            spi_div_cnt <= spi_div_cnt + 1;
                        else
                            spi_div_cnt   <= 0;
                            reg_oled_sclk <= '1'; -- Tepi naik: OLED mencuplik data
                            spi_state     <= SPI_CLK_HIGH;
                        end if;

                    when SPI_CLK_HIGH =>
                        reg_oled_sclk <= '1';
                        if spi_div_cnt + 1 < HALF_DIV then
                            spi_div_cnt <= spi_div_cnt + 1;
                        else
                            spi_div_cnt   <= 0;
                            reg_oled_sclk <= '0'; -- Tepi turun
                            if spi_bit_idx > 0 then
                                spi_bit_idx   <= spi_bit_idx - 1;
                                reg_oled_mosi <= spi_tx_byte(spi_bit_idx - 1);
                                spi_state     <= SPI_CLK_LOW;
                            else
                                -- Seluruh 8 bit selesai ditransmisikan
                                if spi_keep_cs = '1' then
                                    -- Pertahankan CS LOW untuk byte berikutnya
                                    spi_tx_done <= '1';
                                    spi_state   <= SPI_DONE;
                                else
                                    -- Akhiri transfer burst: masuki fase hold time CS
                                    spi_state   <= SPI_HOLD_CS;
                                end if;
                            end if;
                        end if;

                    when SPI_HOLD_CS =>
                        reg_oled_sclk <= '0';
                        if spi_hold_cnt + 1 < CS_HOLD_CYCLES then
                            spi_hold_cnt <= spi_hold_cnt + 1;
                        else
                            spi_hold_cnt <= 0;
                            reg_oled_cs  <= '1'; -- De-assert CS ke HIGH
                            spi_tx_done  <= '1';
                            spi_state    <= SPI_DONE;
                        end if;

                    when SPI_DONE =>
                        -- Tahan pulsa done 1 siklus lalu kembali ke IDLE
                        spi_tx_done <= '0';
                        spi_state   <= SPI_IDLE;

                end case;
            end if;
        end if;
    end process;

    -- -------------------------------------------------------------------------
    -- PROSES UTAMA PENGENDALI OLED (FSM Master Sinkron 100 MHz)
    -- -------------------------------------------------------------------------
    process(clk)
        variable v_bit_val : std_logic;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state         <= ST_RESET_LOW;
                reg_busy      <= '1';
                reg_init_done <= '0';
                reg_oled_res  <= '0';
                reg_oled_dc   <= '0';
                cycle_cnt     <= 0;
                init_idx      <= 0;
                cmd_idx       <= 0;
                page_idx      <= 0;
                block_idx     <= 0;
                fetch_row     <= 0;
                data_col      <= 0;
                wait_cnt      <= 0;
                rd_addr       <= (others => '0');
                spi_tx_start  <= '0';
                spi_keep_cs   <= '0';
                spi_tx_byte   <= (others => '0');
            else
                case state is

                    -- =========================================================
                    -- 1. FASE POWER-ON & RESET FISIK
                    -- =========================================================
                    when ST_RESET_LOW =>
                        reg_busy      <= '1';
                        reg_init_done <= '0';
                        reg_oled_res  <= '0'; -- Aktifkan pulsa reset LOW
                        reg_oled_dc   <= '0';
                        spi_tx_start  <= '0';

                        if cycle_cnt + 1 < RES_LOW_CYCLES then
                            cycle_cnt <= cycle_cnt + 1;
                        else
                            cycle_cnt    <= 0;
                            reg_oled_res <= '1'; -- Lepaskan reset ke HIGH
                            state        <= ST_RESET_WAIT;
                        end if;

                    when ST_RESET_WAIT =>
                        -- Tunggu stabilisasi rangkaian internal SSD1306 pasca-reset
                        reg_oled_res <= '1';
                        if cycle_cnt + 1 < RES_WAIT_CYCLES then
                            cycle_cnt <= cycle_cnt + 1;
                        else
                            cycle_cnt <= 0;
                            init_idx  <= 0;
                            state     <= ST_INIT_BYTE_SETUP;
                        end if;

                    -- =========================================================
                    -- 2. FASE INISIALISASI REGISTER SSD1306 (25 BYTE)
                    -- =========================================================
                    when ST_INIT_BYTE_SETUP =>
                        reg_oled_dc  <= '0'; -- D/C = '0' untuk seluruh perintah inisialisasi
                        spi_tx_byte  <= INIT_CMDS(init_idx);
                        spi_tx_start <= '1';

                        -- Pertahankan CS LOW selama rentetan inisialisasi belum mencapai byte terakhir
                        if init_idx < 24 then
                            spi_keep_cs <= '1';
                        else
                            spi_keep_cs <= '0';
                        end if;

                        state <= ST_INIT_SPI_TX;

                    when ST_INIT_SPI_TX =>
                        spi_tx_start <= '0';
                        if spi_tx_done = '1' then
                            if init_idx < 24 then
                                init_idx <= init_idx + 1;
                                state    <= ST_INIT_BYTE_SETUP;
                            else
                                -- Seluruh 25 byte inisialisasi selesai terkirim
                                reg_init_done <= '1';
                                reg_busy      <= '0';
                                state         <= ST_IDLE;
                            end if;
                        end if;

                    -- =========================================================
                    -- 3. FASE IDLE & MENUNGGU PULSA START FRAME
                    -- =========================================================
                    when ST_IDLE =>
                        reg_busy     <= '0';
                        spi_tx_start <= '0';
                        spi_keep_cs  <= '0';

                        if start = '1' and reg_init_done = '1' then
                            reg_busy  <= '1';
                            cmd_idx   <= 0;
                            page_idx  <= 0;
                            block_idx <= 0;
                            state     <= ST_FRAME_CMD_SETUP;
                        end if;

                    -- =========================================================
                    -- 4. FASE PERINTAH PEMBATAS JENDELA FRAME (6 BYTE)
                    -- =========================================================
                    when ST_FRAME_CMD_SETUP =>
                        reg_oled_dc  <= '0'; -- D/C = '0' untuk perintah batas jendela
                        spi_tx_byte  <= FRAME_CMDS(cmd_idx);
                        spi_tx_start <= '1';

                        if cmd_idx < 5 then
                            spi_keep_cs <= '1';
                        else
                            -- Selesai 6 byte perintah, de-assert CS sebelum beralih ke data
                            spi_keep_cs <= '0';
                        end if;

                        state <= ST_FRAME_CMD_SPI_TX;

                    when ST_FRAME_CMD_SPI_TX =>
                        spi_tx_start <= '0';
                        if spi_tx_done = '1' then
                            if cmd_idx < 5 then
                                cmd_idx <= cmd_idx + 1;
                                state   <= ST_FRAME_CMD_SETUP;
                            else
                                -- Perintah selesai, mulai pembacaan blok data pertama
                                page_idx  <= 0;
                                block_idx <= 0;
                                fetch_row <= 0;
                                state     <= ST_FETCH_BRAM_ADDR;
                            end if;
                        end if;

                    -- =========================================================
                    -- 5. FASE PEMBACAAN 8 BYTE BRAM & TRANSPOSISI
                    -- =========================================================
                    when ST_FETCH_BRAM_ADDR =>
                        -- Hitung alamat BRAM raster: Addr = (8*p + r)*16 + k
                        rd_addr  <= std_logic_vector(to_unsigned((page_idx * 8 + fetch_row) * 16 + block_idx, 10));
                        wait_cnt <= 0;
                        state    <= ST_FETCH_BRAM_WAIT;

                    when ST_FETCH_BRAM_WAIT =>
                        -- Tunggu latensi pembacaan BRAM (READ_LATENCY siklus)
                        if wait_cnt + 1 < READ_LATENCY then
                            wait_cnt <= wait_cnt + 1;
                        else
                            wait_cnt <= 0;
                            state    <= ST_FETCH_BRAM_LATCH;
                        end if;

                    when ST_FETCH_BRAM_LATCH =>
                        tile_buf(fetch_row) <= rd_data;
                        if fetch_row < 7 then
                            fetch_row <= fetch_row + 1;
                            state     <= ST_FETCH_BRAM_ADDR;
                        else
                            fetch_row <= 0;
                            state     <= ST_TRANSPOSE_BLOCK;
                        end if;

                    when ST_TRANSPOSE_BLOCK =>
                        -- Transposisi 8 byte raster ke dalam 8 byte vertikal GDRAM SSD1306
                        -- Untuk tiap kolom c (0..7) dan baris r (0..7):
                        -- Bit r pada byte keluaran c berasal dari bit (7 - c) pada tile_buf(r)
                        for c in 0 to 7 loop
                            for r in 0 to 7 loop
                                v_bit_val := tile_buf(r)(7 - c);
                                if INVERT_DATA then
                                    col_bytes(c)(r) <= not v_bit_val;
                                else
                                    col_bytes(c)(r) <= v_bit_val;
                                end if;
                            end loop;
                        end loop;

                        data_col <= 0;
                        state    <= ST_DATA_BYTE_SETUP;

                    -- =========================================================
                    -- 6. FASE PENGIRIMAN 8 BYTE DATA TRANSPOSED (D/C = '1')
                    -- =========================================================
                    when ST_DATA_BYTE_SETUP =>
                        reg_oled_dc  <= '1'; -- D/C = '1' untuk seluruh muatan data GDRAM
                        spi_tx_byte  <= col_bytes(data_col);
                        spi_tx_start <= '1';

                        -- Pertahankan CS LOW jika masih ada byte data berikutnya dalam frame
                        if (page_idx = 7 and block_idx = 15 and data_col = 7) then
                            spi_keep_cs <= '0'; -- Byte ke-1024 (terakhir): lepaskan CS
                        else
                            spi_keep_cs <= '1';
                        end if;

                        state <= ST_DATA_SPI_TX;

                    when ST_DATA_SPI_TX =>
                        spi_tx_start <= '0';
                        if spi_tx_done = '1' then
                            if data_col < 7 then
                                data_col <= data_col + 1;
                                state    <= ST_DATA_BYTE_SETUP;
                            else
                                -- Selesai 8 byte pada blok k saat ini:
                                if block_idx < 15 then
                                    block_idx <= block_idx + 1;
                                    fetch_row <= 0;
                                    state     <= ST_FETCH_BRAM_ADDR;
                                elsif page_idx < 7 then
                                    page_idx  <= page_idx + 1;
                                    block_idx <= 0;
                                    fetch_row <= 0;
                                    state     <= ST_FETCH_BRAM_ADDR;
                                else
                                    -- Tepat 1.024 byte data frame tuntas terkirim!
                                    state <= ST_FRAME_BURST_END;
                                end if;
                            end if;
                        end if;

                    when ST_FRAME_BURST_END =>
                        -- Akhiri frame: pastikan CS HIGH dan pulihkan busy ke '0'
                        reg_busy    <= '0';
                        spi_keep_cs <= '0';
                        state       <= ST_IDLE;

                end case;
            end if;
        end if;
    end process;

end architecture rtl;

