library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mini_led_uart is
    port (
        clk  : in  std_logic; -- 100 MHz oscillator (pin W5)
        btnC : in  std_logic; -- Reset (pin U18)
        led  : out std_logic; -- Blink indicator (pin U16)
        RsTx : out std_logic  -- UART TX constant byte (pin A18)
    );
end entity mini_led_uart;

architecture rtl of mini_led_uart is
    -- 100 MHz / 921600 baud = 108.5 -> divisor 109
    constant BAUD_DIVISOR : integer := 109;

    signal blink_cnt : unsigned(26 downto 0) := (others => '0');

    -- UART TX FSM
    type state_t is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal state      : state_t := IDLE;
    signal baud_cnt   : integer range 0 to BAUD_DIVISOR - 1 := 0;
    signal bit_idx    : integer range 0 to 7 := 0;
    signal tx_shift   : std_logic_vector(7 downto 0) := x"41"; -- Huruf 'A'
    signal tx_out     : std_logic := '1';
    signal send_timer : unsigned(23 downto 0) := (others => '0');
begin
    led <= blink_cnt(25);
    RsTx <= tx_out;

    process(clk)
    begin
        if rising_edge(clk) then
            if btnC = '1' then
                blink_cnt   <= (others => '0');
                state       <= IDLE;
                baud_cnt    <= 0;
                tx_out      <= '1';
                send_timer  <= (others => '0');
            else
                blink_cnt <= blink_cnt + 1;
                send_timer <= send_timer + 1;

                case state is
                    when IDLE =>
                        tx_out <= '1';
                        baud_cnt <= 0;
                        bit_idx <= 0;
                        if send_timer = 0 then
                            tx_shift <= x"41"; -- Kirim 'A'
                            state <= START_BIT;
                        end if;

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
                        else
                            baud_cnt <= baud_cnt + 1;
                        end if;
                end case;
            end if;
        end if;
    end process;
end architecture rtl;
