-- hdl/frame_buffer.vhd
-- Double-buffer ping-pong BRAM (Bank A dan Bank B, masing-masing 1024 byte).
-- Menerapkan aturan swap bebas tearing:
-- Swap HANYA dilakukan jika (back_ready = 1 AND read_busy = 0) saat swap_req datang.
-- Menghasilkan sinyal status overrun (sink masih sibuk) dan underrun (bank belakang belum siap).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity frame_buffer is
    generic (
        FRAME_BYTES : integer := 1024
    );
    port (
        clk          : in  std_logic;
        rst          : in  std_logic;

        -- Kendali Frame Swap
        swap_req     : in  std_logic; -- Pulsa frame_tick 30 Hz
        read_busy    : in  std_logic; -- Sinyal busy dari ascii_sink
        overrun      : out std_logic; -- Indikator swap ditolak karena sink sibuk
        underrun     : out std_logic; -- Indikator swap ditolak karena bank belakang belum siap

        -- Port Tulis Bank Belakang (dari Decoder/Source)
        s_axis_data  : in  std_logic_vector(7 downto 0);
        s_axis_valid : in  std_logic;
        s_axis_ready : out std_logic;
        s_axis_last  : in  std_logic;

        -- Port Baca Bank Depan (oleh Display / ASCII Sink)
        rd_addr      : in  unsigned(9 downto 0);
        rd_data      : out std_logic_vector(7 downto 0)
    );
end entity frame_buffer;

architecture rtl of frame_buffer is
    -- 2 Bank x 1024 byte = 2048 byte total memori RAMB ganda
    type ram_t is array (0 to 2047) of std_logic_vector(7 downto 0);
    signal mem : ram_t := (others => (others => '0'));

    -- Penunjuk bank: '0' -> Bank 0 depan, Bank 1 belakang; '1' -> Bank 1 depan, Bank 0 belakang
    signal bank_front : std_logic := '0';
    signal back_ready : std_logic := '0';

    signal wr_ptr : unsigned(9 downto 0) := (others => '0');

    signal overrun_reg  : std_logic := '0';
    signal underrun_reg : std_logic := '0';
begin
    overrun  <= overrun_reg;
    underrun <= underrun_reg;

    -- Siap menerima byte baru jika bank belakang BELUM penuh
    s_axis_ready <= '1' when (back_ready = '0') else '0';

    process(clk)
        variable full_wr_addr : integer;
        variable full_rd_addr : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                bank_front   <= '0';
                back_ready   <= '0';
                wr_ptr       <= (others => '0');
                overrun_reg  <= '0';
                underrun_reg <= '0';
                rd_data      <= (others => '0');
            else
                -- 1. Evaluasi Swap Request pada frame_tick
                if swap_req = '1' then
                    if read_busy = '1' then
                        -- Sink masih membaca: tolak swap agar tidak tearing!
                        overrun_reg <= '1';
                    elsif back_ready = '0' then
                        -- Bank belakang belum lengkap: tolak swap!
                        underrun_reg <= '1';
                    else
                        -- Kondisi valid: lakukan swap bank seketika
                        bank_front   <= not bank_front;
                        back_ready   <= '0';
                        wr_ptr       <= (others => '0');
                        overrun_reg  <= '0';
                        underrun_reg <= '0';
                    end if;
                end if;

                -- 2. Penulisan ke Bank Belakang
                if (s_axis_valid = '1' and back_ready = '0') then
                    -- Tentukan alamat fisik bank belakang
                    if bank_front = '0' then
                        full_wr_addr := 1024 + to_integer(wr_ptr); -- Bank 1 belakang
                    else
                        full_wr_addr := to_integer(wr_ptr);        -- Bank 0 belakang
                    end if;

                    mem(full_wr_addr) <= s_axis_data;

                    if (s_axis_last = '1' or wr_ptr = FRAME_BYTES - 1) then
                        back_ready <= '1';
                    else
                        wr_ptr <= wr_ptr + 1;
                    end if;
                end if;

                -- 3. Pembacaan Synchronous dari Bank Depan
                if bank_front = '0' then
                    full_rd_addr := to_integer(rd_addr);        -- Bank 0 depan
                else
                    full_rd_addr := 1024 + to_integer(rd_addr); -- Bank 1 depan
                end if;

                rd_data <= mem(full_rd_addr);
            end if;
        end if;
    end process;
end architecture rtl;
