-- hdl/uart_rx.vhd
-- Modul Penerima Serial UART 8N1 (Milestone M2)
-- Menangani:
-- 1. Sinkronisasi input 2 flip-flop untuk mencegah metastabilitas pada pin RsRx.
-- 2. Deteksi falling edge start bit dan sampling di titik tengah bit (mid-bit sampling).
-- 3. Penerimaan 8 bit data LSB first dan verifikasi stop bit.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_rx is
    generic (
        CLK_FREQ_HZ : integer := 100_000_000;
        BAUD_RATE   : integer := 921_600
    );
    port (
        clk     : in  std_logic;
        rst     : in  std_logic;
        rx      : in  std_logic;
        m_data  : out std_logic_vector(7 downto 0);
        m_valid : out std_logic
    );
end entity uart_rx;

architecture rtl of uart_rx is
    constant CLKS_PER_BIT : integer := (CLK_FREQ_HZ + BAUD_RATE / 2) / BAUD_RATE; -- 109 pada 100MHz/921600
    constant HALF_BIT     : integer := CLKS_PER_BIT / 2;                           -- 54 (titik tengah bit)

    -- 2-FF Synchronizer
    signal rx_meta : std_logic := '1';
    signal rx_sync : std_logic := '1';

    -- FSM State
    type state_t is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal state : state_t := IDLE;

    signal clk_cnt : integer range 0 to CLKS_PER_BIT - 1 := 0;
    signal bit_idx : integer range 0 to 7 := 0;
    signal rx_shreg : std_logic_vector(7 downto 0) := (others => '0');

    signal data_out_reg : std_logic_vector(7 downto 0) := (others => '0');
    signal valid_out_reg : std_logic := '0';
begin
    m_data  <= data_out_reg;
    m_valid <= valid_out_reg;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                rx_meta       <= '1';
                rx_sync       <= '1';
                state         <= IDLE;
                clk_cnt       <= 0;
                bit_idx       <= 0;
                rx_shreg      <= (others => '0');
                data_out_reg  <= (others => '0');
                valid_out_reg <= '0';
            else
                -- 2-FF sync
                rx_meta <= rx;
                rx_sync <= rx_meta;

                valid_out_reg <= '0';  -- Default 1-siklus pulsa

                case state is
                    when IDLE =>
                        clk_cnt <= 0;
                        bit_idx <= 0;
                        if rx_sync = '0' then
                            -- Deteksi awal start bit
                            state <= START_BIT;
                        end if;

                    when START_BIT =>
                        if clk_cnt = HALF_BIT - 1 then
                            if rx_sync = '0' then
                                -- Start bit valid pada titik tengah
                                clk_cnt <= 0;
                                state   <= DATA_BITS;
                            else
                                -- Glitch palsu
                                state <= IDLE;
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;

                    when DATA_BITS =>
                        if clk_cnt = CLKS_PER_BIT - 1 then
                            clk_cnt <= 0;
                            rx_shreg(bit_idx) <= rx_sync;  -- LSB first
                            if bit_idx = 7 then
                                bit_idx <= 0;
                                state   <= STOP_BIT;
                            else
                                bit_idx <= bit_idx + 1;
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;

                    when STOP_BIT =>
                        -- FSM masuk STOP_BIT tepat setelah mencuplik bit data ke-7 di tengah bit itu (8,5 bit dari tepi start). Menunggu HALF_BIT mencuplik pada batas data/stop (9,0 bit); menunggu CLKS_PER_BIT - 1 mencuplik di tengah stop bit (9,5 bit).
                        -- Terverifikasi xsim pada periode 1055..1115 ns (+-2,76%). Batas teoretis hitungan tangan kira-kira P dalam (1036, 1150) ns [DIASUMSIKAN]. Pada 31a1007, batas lambat sekitar -0,4% baud [DIVERIFIKASI oleh matriks xsim].
                        if clk_cnt = CLKS_PER_BIT - 1 then
                            clk_cnt <= 0;
                            state   <= IDLE;
                            if rx_sync = '1' then
                                -- Stop bit valid
                                data_out_reg  <= rx_shreg;
                                valid_out_reg <= '1';
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;

end architecture rtl;

