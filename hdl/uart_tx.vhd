-- hdl/uart_tx.vhd
-- Transmiter UART Serial 8N1 dengan antarmuka handshake valid/ready.
-- Mendukung baud rate fleksibel melalui generic CLK_FREQ_HZ dan BAUD_RATE.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity uart_tx is
    generic (
        CLK_FREQ_HZ : integer := 100_000_000;
        BAUD_RATE   : integer := 921_600
    );
    port (
        clk      : in  std_logic;
        rst      : in  std_logic;
        tx_data  : in  std_logic_vector(7 downto 0);
        tx_valid : in  std_logic;
        tx_ready : out std_logic;
        RsTx     : out std_logic
    );
end entity uart_tx;

architecture rtl of uart_tx is
    -- Pembagi clock integer terdekat
    constant CLKS_PER_BIT : integer := (CLK_FREQ_HZ + BAUD_RATE / 2) / BAUD_RATE;

    type state_t is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal state : state_t := IDLE;

    signal clk_cnt  : integer range 0 to CLKS_PER_BIT - 1 := 0;
    signal bit_idx  : integer range 0 to 7 := 0;
    signal tx_shift : std_logic_vector(7 downto 0) := (others => '1');
    signal tx_line  : std_logic := '1';
begin
    RsTx <= tx_line;

    -- Transmiter siap menerima byte baru HANYA saat kondisi IDLE
    tx_ready <= '1' when (state = IDLE) else '0';

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state    <= IDLE;
                clk_cnt  <= 0;
                bit_idx  <= 0;
                tx_shift <= (others => '1');
                tx_line  <= '1';
            else
                case state is
                    when IDLE =>
                        tx_line <= '1';
                        clk_cnt <= 0;
                        bit_idx <= 0;
                        if tx_valid = '1' then
                            tx_shift <= tx_data;
                            state    <= START_BIT;
                        end if;

                    when START_BIT =>
                        tx_line <= '0'; -- Start bit selalu 0
                        if clk_cnt = CLKS_PER_BIT - 1 then
                            clk_cnt <= 0;
                            state   <= DATA_BITS;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;

                    when DATA_BITS =>
                        tx_line <= tx_shift(bit_idx); -- LSB first
                        if clk_cnt = CLKS_PER_BIT - 1 then
                            clk_cnt <= 0;
                            if bit_idx = 7 then
                                state <= STOP_BIT;
                            else
                                bit_idx <= bit_idx + 1;
                            end if;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;

                    when STOP_BIT =>
                        tx_line <= '1'; -- Stop bit selalu 1
                        if clk_cnt = CLKS_PER_BIT - 1 then
                            clk_cnt <= 0;
                            state   <= IDLE;
                        else
                            clk_cnt <= clk_cnt + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;
end architecture rtl;
