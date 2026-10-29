-- hdl/rx_fifo.vhd
-- Buffer FIFO RX 2 KB (2048 x 8) berbasis Block RAM (RAMB18E1)
-- Mendukung pointer baca ganda:
-- 1. r_ptr_commit: posisi byte yang telah resmi dikonfirmasi/dikeluarkan dari FIFO.
-- 2. r_ptr_spec: pointer baca spekulatif untuk parser paket.
-- 3. mark_sof: menandai alamat awal SOF untuk kemungkinan rollback.
-- 4. commit: paket valid, majukan commit pointer (r_ptr_commit <= r_ptr_spec).
-- 5. rollback: galat/sinkron palsu, kembalikan r_ptr_spec dan r_ptr_commit ke (r_ptr_sof + 1).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rx_fifo is
    generic (
        FIFO_DEPTH : integer := 2048
    );
    port (
        clk          : in  std_logic;
        rst          : in  std_logic;

        -- Sisi Tulis (dari uart_rx)
        wr_en        : in  std_logic;
        wr_data      : in  std_logic_vector(7 downto 0);
        full         : out std_logic;

        -- Sisi Baca Spekulatif (ke packet_parser)
        rd_req       : in  std_logic;
        rd_data      : out std_logic_vector(7 downto 0);
        spec_empty   : out std_logic;

        -- Kontrol Spekulatif & Transaksi Paket
        mark_sof     : in  std_logic;
        commit       : in  std_logic;
        rollback     : in  std_logic;

        -- Status Buffer
        commit_empty : out std_logic;
        overflow_err : out std_logic
    );
end entity rx_fifo;

architecture rtl of rx_fifo is
    type ram_t is array (0 to FIFO_DEPTH - 1) of std_logic_vector(7 downto 0);
    signal mem : ram_t;

    signal w_ptr        : unsigned(10 downto 0) := (others => '0');
    signal r_ptr_commit : unsigned(10 downto 0) := (others => '0');
    signal r_ptr_spec   : unsigned(10 downto 0) := (others => '0');
    signal r_ptr_sof    : unsigned(10 downto 0) := (others => '0');

    signal is_full      : std_logic;
    signal is_spec_empty : std_logic;
    signal is_commit_empty : std_logic;
    signal overflow_reg : std_logic := '0';
begin
    full         <= is_full;
    spec_empty   <= is_spec_empty;
    commit_empty <= is_commit_empty;
    overflow_err <= overflow_reg;

    is_full         <= '1' when (w_ptr + 1 = r_ptr_commit) else '0';
    is_spec_empty   <= '1' when (r_ptr_spec = w_ptr) else '0';
    is_commit_empty <= '1' when (r_ptr_commit = w_ptr) else '0';

    -- 1. Pembacaan BRAM Sinkron Murni (Unconditional Synchronous Read)
    -- Memastikan Vivado menginferensi 1x RAMB18E1 tanpa peringatan Synth 8-6040
    process(clk)
    begin
        if rising_edge(clk) then
            rd_data <= mem(to_integer(r_ptr_spec));
        end if;
    end process;

    -- 2. Penulisan BRAM Sinkron
    process(clk)
    begin
        if rising_edge(clk) then
            if wr_en = '1' and is_full = '0' then
                mem(to_integer(w_ptr)) <= wr_data;
            end if;
        end if;
    end process;

    -- 3. Logika Manajemen Pointer
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                w_ptr        <= (others => '0');
                r_ptr_commit <= (others => '0');
                r_ptr_spec   <= (others => '0');
                r_ptr_sof    <= (others => '0');
                overflow_reg <= '0';
            else
                -- Penulisan data
                if wr_en = '1' then
                    if is_full = '1' then
                        overflow_reg <= '1';
                    else
                        w_ptr <= w_ptr + 1;
                    end if;
                end if;

                -- Transaksi spekulatif
                if rollback = '1' then
                    -- Rollback saat paket salah / sinkron palsu
                    r_ptr_spec   <= r_ptr_sof + 1;
                    r_ptr_commit <= r_ptr_sof + 1;
                elsif commit = '1' then
                    -- Komit saat paket valid selesai diterima
                    r_ptr_commit <= r_ptr_spec;
                end if;

                if mark_sof = '1' then
                    r_ptr_sof <= r_ptr_spec;
                end if;

                -- Majukan pointer baca spekulatif saat ada permintaan baca
                if rd_req = '1' and is_spec_empty = '0' then
                    r_ptr_spec <= r_ptr_spec + 1;
                end if;
            end if;
        end if;
    end process;

end architecture rtl;

