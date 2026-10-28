-- hdl/frame_source.vhd
-- Modul frame_source untuk M1: membaca klip 90 frame (1024 byte/frame format kanonik)
-- dari BRAM onboard dan men-stream ke antarmuka AXI-Stream valid/ready.
-- Menggunakan arsitektur prefetch pipeline 32-bit untuk menjamin 100% throughput 1 byte/siklus
-- tanpa bubble atau data delay.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity frame_source is
    generic (
        TOTAL_FRAMES : integer := 90;
        FRAME_BYTES  : integer := 1024;
        INIT_FILE    : string  := "data/golden/clip_bram_32bit.hex";
        FREE_RUNNING : boolean := true
    );
    port (
        clk          : in  std_logic;
        rst          : in  std_logic;
        start_frame  : in  std_logic;
        m_axis_data  : out std_logic_vector(7 downto 0);
        m_axis_valid : out std_logic;
        m_axis_last  : out std_logic;
        m_axis_ready : in  std_logic
    );
end entity frame_source;

architecture rtl of frame_source is
    constant TOTAL_BYTES : integer := TOTAL_FRAMES * FRAME_BYTES; -- 92.160 byte
    constant TOTAL_WORDS : integer := TOTAL_BYTES / 4;            -- 23.040 word (32-bit)

    type rom_t is array (0 to TOTAL_WORDS - 1) of std_logic_vector(31 downto 0);

    impure function init_rom_from_file(path : string) return rom_t is
        file f : text open read_mode is path;
        variable l : line;
        variable res : rom_t;
        variable val : std_logic_vector(31 downto 0);
    begin
        for i in 0 to TOTAL_WORDS - 1 loop
            if not endfile(f) then
                readline(f, l);
                hread(l, val);
                res(i) := val;
            else
                res(i) := (others => '0');
            end if;
        end loop;
        return res;
    end function;

    signal rom : rom_t := init_rom_from_file(INIT_FILE);

    type state_t is (IDLE, INIT_LOAD_0, INIT_LOAD_1, STREAMING);
    signal state : state_t := IDLE;

    signal frame_idx  : integer range 0 to TOTAL_FRAMES - 1 := 0;
    signal byte_idx   : integer range 0 to FRAME_BYTES - 1  := 0;
    signal word_addr  : integer range 0 to TOTAL_WORDS - 1  := 0;
    signal bytes_left : integer range 0 to 4                := 0;

    signal shift_reg  : std_logic_vector(31 downto 0) := (others => '0');
    signal rword      : std_logic_vector(31 downto 0) := (others => '0');
begin
    m_axis_data  <= shift_reg(31 downto 24);
    m_axis_valid <= '1' when (state = STREAMING and bytes_left > 0) else '0';
    m_axis_last  <= '1' when (state = STREAMING and byte_idx = FRAME_BYTES - 1) else '0';

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                frame_idx  <= 0;
                byte_idx   <= 0;
                word_addr  <= 0;
                bytes_left <= 0;
                shift_reg  <= (others => '0');
                rword      <= (others => '0');
                if FREE_RUNNING then
                    state <= INIT_LOAD_0;
                else
                    state <= IDLE;
                end if;
            else
                case state is
                    when IDLE =>
                        if start_frame = '1' then
                            state <= INIT_LOAD_0;
                        end if;

                    when INIT_LOAD_0 =>
                        -- Baca kata 0 dari ROM
                        rword     <= rom(0);
                        word_addr <= 1;
                        state     <= INIT_LOAD_1;

                    when INIT_LOAD_1 =>
                        -- Muat kata 0 ke shift register, prefetch kata 1
                        shift_reg  <= rword;
                        rword      <= rom(word_addr);
                        word_addr  <= word_addr + 1;
                        bytes_left <= 4;
                        state      <= STREAMING;

                    when STREAMING =>
                        if m_axis_ready = '1' then
                            -- 1. Perbarui indeks byte dalam frame
                            if byte_idx = FRAME_BYTES - 1 then
                                byte_idx <= 0;
                                if frame_idx = TOTAL_FRAMES - 1 then
                                    frame_idx <= 0;
                                else
                                    frame_idx <= frame_idx + 1;
                                end if;

                                if not FREE_RUNNING then
                                    state <= IDLE;
                                end if;
                            else
                                byte_idx <= byte_idx + 1;
                            end if;

                            -- 2. Geser data dan reload kata jika habis
                            shift_reg <= shift_reg(23 downto 0) & x"00";

                            if bytes_left = 1 then
                                -- Muat kata yang sudah di-prefetch
                                shift_reg  <= rword;
                                bytes_left <= 4;
                                -- Prefetch kata berikutnya dari ROM
                                rword      <= rom(word_addr);
                                if word_addr = TOTAL_WORDS - 1 then
                                    word_addr <= 0;
                                else
                                    word_addr <= word_addr + 1;
                                end if;
                            else
                                bytes_left <= bytes_left - 1;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;
end architecture rtl;
