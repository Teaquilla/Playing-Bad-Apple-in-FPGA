-- hdl/frame_buffer.vhd
-- Double-buffer ping-pong BRAM (Bank A dan Bank B, masing-masing 1024 byte).
-- Menerapkan aturan swap bebas tearing:
-- M1: Swap HANYA dilakukan jika (back_ready = 1 AND read_busy = 0) saat swap_req datang.
-- M2: Mode streaming dengan swap tertunda (delayed swap) saat packet_valid tiba dan read_busy = 0.
--     Jika read_busy = 1 saat packet_valid, swap ditahan (pending_swap = 1) sampai sink idle.
--     Jika paket berikutnya tiba saat pending_swap = 1, frame baru dibuang dan stream_overrun aktif.
--     Jika stream_drop = 1 (checksum/dekoder galat), frame dibuang dan frame lama tetap tampil.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity frame_buffer is
    generic (
        FRAME_BYTES : integer := 1024
    );
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;

        -- Konfigurasi Mode
        streaming_mode  : in  std_logic := '0';

        -- Kendali Frame Swap Mode M1
        swap_req        : in  std_logic := '0'; -- Pulsa frame_tick 30 Hz
        read_busy       : in  std_logic := '0'; -- Sinyal busy dari ascii_sink
        overrun         : out std_logic;        -- Indikator swap ditolak karena sink sibuk (M1)
        underrun        : out std_logic;        -- Indikator swap ditolak karena bank belakang belum siap (M1)

        -- Kendali Streaming Mode M2
        stream_valid    : in  std_logic := '0'; -- Pulsa packet_valid dari packet_parser
        stream_drop     : in  std_logic := '0'; -- Pulsa error (buang frame bank belakang)
        stream_overrun  : out std_logic;        -- Pulsa overrun streaming (paket baru tiba saat swap tertunda)
        swap_done       : out std_logic;        -- Pulsa 1-siklus saat swap dieksekusi

        -- Port Tulis Bank Belakang (dari Decoder/Source)
        s_axis_data     : in  std_logic_vector(7 downto 0);
        s_axis_valid    : in  std_logic;
        s_axis_ready    : out std_logic;
        s_axis_last     : in  std_logic;

        -- Port Baca Bank Depan (oleh Display / ASCII Sink)
        rd_addr         : in  unsigned(9 downto 0);
        rd_data         : out std_logic_vector(7 downto 0)
    );
end entity frame_buffer;

architecture rtl of frame_buffer is
    -- 2 Bank x 1024 byte = 2048 byte total memori RAMB ganda
    type ram_t is array (0 to 2047) of std_logic_vector(7 downto 0);
    signal mem : ram_t := (others => (others => '0'));

    -- Penunjuk bank: '0' -> Bank 0 depan, Bank 1 belakang; '1' -> Bank 1 depan, Bank 0 belakang
    signal bank_front : std_logic := '0';
    signal back_ready : std_logic := '0';

    -- Status swap tertunda pada mode streaming
    signal pending_swap       : std_logic := '0';
    signal stream_overrun_reg : std_logic := '0';
    signal swap_done_reg      : std_logic := '0';

    signal wr_ptr : unsigned(9 downto 0) := (others => '0');

    signal overrun_reg  : std_logic := '0';
    signal underrun_reg : std_logic := '0';
begin
    overrun        <= overrun_reg;
    underrun       <= underrun_reg;
    stream_overrun <= stream_overrun_reg;
    swap_done      <= swap_done_reg;

    -- Siap menerima byte baru jika bank belakang BELUM penuh/menunggu swap
    s_axis_ready <= '1' when (streaming_mode = '0' and back_ready = '0') or
                             (streaming_mode = '1' and pending_swap = '0') else '0';

    process(clk)
        variable full_wr_addr : integer;
        variable full_rd_addr : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                bank_front         <= '0';
                back_ready         <= '0';
                pending_swap       <= '0';
                stream_overrun_reg <= '0';
                swap_done_reg      <= '0';
                wr_ptr             <= (others => '0');
                overrun_reg        <= '0';
                underrun_reg       <= '0';
                rd_data            <= (others => '0');
            else
                stream_overrun_reg <= '0';  -- Default pulsa 1 siklus
                swap_done_reg      <= '0';  -- Default pulsa 1 siklus

                if streaming_mode = '0' then
                    ------------------------------------------------------------
                    -- LOGIKA MODE M1 (KLIP BRAM DENGAN FRAME TIMER 30 FPS)
                    ------------------------------------------------------------
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
                            bank_front    <= not bank_front;
                            back_ready    <= '0';
                            wr_ptr        <= (others => '0');
                            overrun_reg   <= '0';
                            underrun_reg  <= '0';
                            swap_done_reg <= '1';
                        end if;
                    end if;

                    -- 2. Penulisan ke Bank Belakang
                    if (s_axis_valid = '1' and back_ready = '0') then
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

                else
                    ------------------------------------------------------------
                    -- LOGIKA MODE M2 (STREAMING UART RX DENGAN SWAP TERTUNDA)
                    ------------------------------------------------------------
                    -- 1. Penanganan Galat / Drop Request (Checksum / Dekoder Error)
                    if stream_drop = '1' then
                        -- Buang frame yang rusak: reset pointer tulis bank belakang
                        wr_ptr       <= (others => '0');
                        pending_swap <= '0';
                    -- 2. Penanganan Paket Valid yang Tiba
                    elsif stream_valid = '1' then
                        if pending_swap = '1' then
                            -- Paket baru tiba saat frame sebelumnya masih menunggu swap!
                            -- Buang paket baru dan catat overrun streaming
                            stream_overrun_reg <= '1';
                            wr_ptr             <= (others => '0');
                        else
                            if read_busy = '0' then
                                -- Sink sedang idle: langsung swap seketika!
                                bank_front    <= not bank_front;
                                pending_swap  <= '0';
                                wr_ptr        <= (others => '0');
                                swap_done_reg <= '1';
                            else
                                -- Sink masih membaca frame sebelumnya: tahan swap sampai idle
                                pending_swap <= '1';
                            end if;
                        end if;
                    -- 3. Eksekusi Swap Tertunda Saat Sink Selesai Membaca
                    elsif pending_swap = '1' and read_busy = '0' then
                        bank_front    <= not bank_front;
                        pending_swap  <= '0';
                        wr_ptr        <= (others => '0');
                        swap_done_reg <= '1';
                    end if;

                    -- 4. Penulisan Byte dari RLE Decoder ke Bank Belakang
                    if s_axis_valid = '1' and pending_swap = '0' then
                        if bank_front = '0' then
                            full_wr_addr := 1024 + to_integer(wr_ptr);
                        else
                            full_wr_addr := to_integer(wr_ptr);
                        end if;

                        mem(full_wr_addr) <= s_axis_data;

                        if wr_ptr < FRAME_BYTES - 1 then
                            wr_ptr <= wr_ptr + 1;
                        end if;
                    end if;
                end if;

                -- Pembacaan Synchronous dari Bank Depan (Berlaku untuk kedua mode)
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
