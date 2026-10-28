library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;

entity mini_bram_clip is
    port (
        clk  : in  std_logic;
        btnC : in  std_logic;
        led  : out std_logic;
        RsTx : out std_logic
    );
end entity mini_bram_clip;

architecture rtl of mini_bram_clip is
    constant BAUD_DIVISOR    : integer := 109; -- 921600 baud dari 100 MHz
    constant ROM_DEPTH_WORDS : integer := 23040; -- 92.160 byte / 4 byte = 23.040 word (loop < 65.536!)

    type rom_t is array (0 to ROM_DEPTH_WORDS - 1) of std_logic_vector(31 downto 0);

    impure function init_rom(file_path : string) return rom_t is
        file f : text open read_mode is file_path;
        variable l : line;
        variable res : rom_t;
        variable val : std_logic_vector(31 downto 0);
    begin
        for i in 0 to ROM_DEPTH_WORDS - 1 loop
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

    signal rom_data : rom_t := init_rom("data/golden/clip_bram_32bit.hex");

    signal word_addr : integer range 0 to ROM_DEPTH_WORDS - 1 := 0;
    signal byte_sel  : integer range 0 to 3 := 0;
    signal rword     : std_logic_vector(31 downto 0) := (others => '0');
    signal rdata     : std_logic_vector(7 downto 0)  := (others => '0');

    signal blink_cnt : unsigned(26 downto 0) := (others => '0');

    -- UART TX FSM
    type state_t is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal state    : state_t := IDLE;
    signal baud_cnt : integer range 0 to BAUD_DIVISOR - 1 := 0;
    signal bit_idx  : integer range 0 to 7 := 0;
    signal tx_shift : std_logic_vector(7 downto 0) := (others => '1');
    signal tx_out   : std_logic := '1';
begin
    led <= blink_cnt(25);
    RsTx <= tx_out;

    -- Ekstraksi byte dari 32-bit word
    with byte_sel select
        rdata <= rword(31 downto 24) when 0,
                 rword(23 downto 16) when 1,
                 rword(15 downto 8)  when 2,
                 rword(7 downto 0)   when others;

    process(clk)
    begin
        if rising_edge(clk) then
            if btnC = '1' then
                blink_cnt <= (others => '0');
                word_addr <= 0;
                byte_sel  <= 0;
                state     <= IDLE;
                baud_cnt  <= 0;
                tx_out    <= '1';
            else
                blink_cnt <= blink_cnt + 1;

                -- Pembacaan BRAM synchronous
                rword <= rom_data(word_addr);

                case state is
                    when IDLE =>
                        tx_out <= '1';
                        baud_cnt <= 0;
                        bit_idx <= 0;
                        tx_shift <= rdata;
                        state <= START_BIT;

                    when START_BIT =>
                        tx_out <= '0';
                        if baud_cnt = BAUD_DIVISOR - 1 then
                            baud_cnt <= 0;
                            state <= DATA_BITS;
                        else
                            baud_cnt <= baud_cnt + 1;
                        end if;

                    when DATA_BITS =>
                        tx_out <= tx_shift(bit_idx);
                        if baud_cnt = BAUD_DIVISOR - 1 then
                            baud_cnt <= 0;
                            if bit_idx = 7 then
                                state <= STOP_BIT;
                            else
                                bit_idx <= bit_idx + 1;
                            end if;
                        else
                            baud_cnt <= baud_cnt + 1;
                        end if;

                    when STOP_BIT =>
                        tx_out <= '1';
                        if baud_cnt = BAUD_DIVISOR - 1 then
                            baud_cnt <= 0;
                            state <= IDLE;
                            -- Pindah ke byte / word BRAM berikutnya
                            if byte_sel = 3 then
                                byte_sel <= 0;
                                if word_addr = ROM_DEPTH_WORDS - 1 then
                                    word_addr <= 0;
                                else
                                    word_addr <= word_addr + 1;
                                end if;
                            else
                                byte_sel <= byte_sel + 1;
                            end if;
                        else
                            baud_cnt <= baud_cnt + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;
end architecture rtl;
