-- hdl/ascii_sink.vhd
-- Renderer ASCII hardware sesuai SPEC bagian 5.1 dan ARCHITECTURE 4.3.
-- Memetakan blok 2x4 piksel dari kanvas 128x64 kanonik ke karakter ASCII 64x16.
-- Menggunakan Ramp A (" .:-=+*#@") dengan densitas 0..8.
-- Menghasilkan tepat 1.059 byte per frame (\x1b[H + 16 baris x (64 char + \r\n)).

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity ascii_sink is
    generic (
        RAMP_SELECT : string := "RAMP_A"
    );
    port (
        clk      : in  std_logic;
        rst      : in  std_logic;

        -- Sinyal start dari frame_tick
        start    : in  std_logic;
        busy     : out std_logic;

        -- Antarmuka Baca Frame Buffer (Synchronous BRAM)
        fb_addr  : out unsigned(9 downto 0);
        fb_data  : in  std_logic_vector(7 downto 0);

        -- Antarmuka Stream ke UART TX
        tx_data  : out std_logic_vector(7 downto 0);
        tx_valid : out std_logic;
        tx_ready : in  std_logic
    );
end entity ascii_sink;

architecture rtl of ascii_sink is
    type state_t is (
        IDLE,
        SEND_ESC_0, SEND_ESC_1, SEND_ESC_2, -- \x1b, '[', 'H'
        FETCH_ROW_0, WAIT_ROW_0,
        FETCH_ROW_1, WAIT_ROW_1,
        FETCH_ROW_2, WAIT_ROW_2,
        FETCH_ROW_3, WAIT_ROW_3,
        CALC_CHAR,
        SEND_CHAR,
        SEND_CR,
        SEND_LF
    );
    signal state : state_t := IDLE;

    signal cur_row : integer range 0 to 15 := 0; -- 16 baris karakter
    signal cur_col : integer range 0 to 63 := 0; -- 64 kolom karakter

    -- Penampung piksel 2x4 (baris y+0, y+1, y+2 disimpan antar siklus)
    signal b0, b1, b2 : std_logic_vector(7 downto 0) := (others => '0');

    -- Lookup table Ramp A: " .:-=+*#@"
    function get_ramp_char(density : integer range 0 to 8) return std_logic_vector is
    begin
        case density is
            when 0 => return x"20"; -- ' '
            when 1 => return x"2E"; -- '.'
            when 2 => return x"3A"; -- ':'
            when 3 => return x"2D"; -- '-'
            when 4 => return x"3D"; -- '='
            when 5 => return x"2B"; -- '+'
            when 6 => return x"2A"; -- '*'
            when 7 => return x"23"; -- '#'
            when 8 => return x"40"; -- '@'
        end case;
    end function;

    -- Ekstrak 2 piksel dari byte berdasarkan cur_col mod 4
    function extract_2pixels(byte_val : std_logic_vector(7 downto 0); col_mod_4 : integer) return integer is
        variable p1, p0 : integer;
    begin
        case col_mod_4 is
            when 0 =>
                p1 := 1 when byte_val(7) = '1' else 0;
                p0 := 1 when byte_val(6) = '1' else 0;
            when 1 =>
                p1 := 1 when byte_val(5) = '1' else 0;
                p0 := 1 when byte_val(4) = '1' else 0;
            when 2 =>
                p1 := 1 when byte_val(3) = '1' else 0;
                p0 := 1 when byte_val(2) = '1' else 0;
            when others =>
                p1 := 1 when byte_val(1) = '1' else 0;
                p0 := 1 when byte_val(0) = '1' else 0;
        end case;
        return p1 + p0;
    end function;

    signal internal_busy : std_logic := '0';
begin
    busy <= internal_busy;

    process(clk)
        variable y_base    : integer;
        variable byte_col  : integer;
        variable b3        : std_logic_vector(7 downto 0);
        variable d0, d1, d2, d3 : integer;
        variable total_density  : integer range 0 to 8;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state         <= IDLE;
                internal_busy <= '0';
                cur_row       <= 0;
                cur_col       <= 0;
                fb_addr       <= (others => '0');
                tx_valid      <= '0';
                tx_data       <= (others => '0');
            else
                case state is
                    when IDLE =>
                        tx_valid <= '0';
                        if start = '1' then
                            internal_busy <= '1';
                            cur_row       <= 0;
                            cur_col       <= 0;
                            tx_data       <= x"1B";
                            tx_valid      <= '1';
                            state         <= SEND_ESC_0;
                        else
                            internal_busy <= '0';
                        end if;

                    -- 1. Escape Sequence: "\x1b[H" (3 byte)
                    when SEND_ESC_0 =>
                        if tx_ready = '1' then
                            tx_data <= x"5B"; -- '['
                            state   <= SEND_ESC_1;
                        end if;

                    when SEND_ESC_1 =>
                        if tx_ready = '1' then
                            tx_data <= x"48"; -- 'H'
                            state   <= SEND_ESC_2;
                        end if;

                    when SEND_ESC_2 =>
                        if tx_ready = '1' then
                            tx_valid <= '0';
                            state    <= FETCH_ROW_0;
                        end if;

                    -- 2. Ambil 4 baris piksel dari BRAM untuk karakter (cur_col, cur_row)
                    when FETCH_ROW_0 =>
                        tx_valid <= '0';
                        y_base   := cur_row * 4;
                        byte_col := cur_col / 4;
                        fb_addr  <= to_unsigned(y_base * 16 + byte_col, 10);
                        state    <= WAIT_ROW_0;

                    when WAIT_ROW_0 =>
                        state <= FETCH_ROW_1;

                    when FETCH_ROW_1 =>
                        b0       <= fb_data; -- Simpan baris y+0
                        y_base   := cur_row * 4 + 1;
                        byte_col := cur_col / 4;
                        fb_addr  <= to_unsigned(y_base * 16 + byte_col, 10);
                        state    <= WAIT_ROW_1;

                    when WAIT_ROW_1 =>
                        state <= FETCH_ROW_2;

                    when FETCH_ROW_2 =>
                        b1       <= fb_data; -- Simpan baris y+1
                        y_base   := cur_row * 4 + 2;
                        byte_col := cur_col / 4;
                        fb_addr  <= to_unsigned(y_base * 16 + byte_col, 10);
                        state    <= WAIT_ROW_2;

                    when WAIT_ROW_2 =>
                        state <= FETCH_ROW_3;

                    when FETCH_ROW_3 =>
                        b2       <= fb_data; -- Simpan baris y+2
                        y_base   := cur_row * 4 + 3;
                        byte_col := cur_col / 4;
                        fb_addr  <= to_unsigned(y_base * 16 + byte_col, 10);
                        state    <= WAIT_ROW_3;

                    when WAIT_ROW_3 =>
                        state <= CALC_CHAR;

                    when CALC_CHAR =>
                        b3 := fb_data; -- Baris y+3 dibaca langsung dari output BRAM
                        d0 := extract_2pixels(b0, cur_col mod 4);
                        d1 := extract_2pixels(b1, cur_col mod 4);
                        d2 := extract_2pixels(b2, cur_col mod 4);
                        d3 := extract_2pixels(b3, cur_col mod 4);
                        total_density := d0 + d1 + d2 + d3;
                        tx_data       <= get_ramp_char(total_density);
                        tx_valid      <= '1';
                        state         <= SEND_CHAR;

                    -- 3. Kirim karakter ASCII via UART TX
                    when SEND_CHAR =>
                        if tx_ready = '1' then
                            if cur_col = 63 then
                                cur_col  <= 0;
                                tx_data  <= x"0D"; -- '\r'
                                state    <= SEND_CR;
                            else
                                cur_col  <= cur_col + 1;
                                tx_valid <= '0';
                                state    <= FETCH_ROW_0;
                            end if;
                        end if;

                    -- 4. Kirim '\r' (0x0D) di akhir baris
                    when SEND_CR =>
                        if tx_ready = '1' then
                            tx_data <= x"0A"; -- '\n'
                            state   <= SEND_LF;
                        end if;

                    -- 5. Kirim '\n' (0x0A) di akhir baris
                    when SEND_LF =>
                        if tx_ready = '1' then
                            tx_valid <= '0';
                            if cur_row = 15 then
                                -- Selesai 1 frame utuh (1059 byte)
                                cur_row       <= 0;
                                internal_busy <= '0';
                                state         <= IDLE;
                            else
                                cur_row <= cur_row + 1;
                                state   <= FETCH_ROW_0;
                            end if;
                        end if;
                end case;
            end if;
        end if;
    end process;
end architecture rtl;
