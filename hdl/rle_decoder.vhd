-- hdl/rle_decoder.vhd
-- Dekoder RLE per Baris 8-bit ke Format Kanonik 1.024 Byte (Milestone M2)
-- Menghasilkan 1.024 byte per frame (128x64 kanonik biner)
-- Mendeteksi galat:
-- 1. Run length > 128 atau akumulasi baris > 128 piksel (err_run)
-- 2. Total byte keluaran != 1.024 saat paket selesai (err_len)

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity rle_decoder is
    generic (
        FRAME_WIDTH  : integer := 128;
        FRAME_HEIGHT : integer := 64;
        TOTAL_BYTES  : integer := 1024
    );
    port (
        clk          : in  std_logic;
        rst          : in  std_logic;

        -- Aliran Masukan RLE (dari packet_parser)
        s_axis_data  : in  std_logic_vector(7 downto 0);
        s_axis_valid : in  std_logic;
        s_axis_ready : out std_logic;
        s_axis_last  : in  std_logic;

        -- Aliran Keluaran Kanonik (ke frame_buffer)
        m_axis_data  : out std_logic_vector(7 downto 0);
        m_axis_valid : out std_logic;
        m_axis_ready : in  std_logic;
        m_axis_last  : out std_logic;

        -- Sinyal Status & Galat
        frame_done   : out std_logic;
        err_run      : out std_logic;
        err_len      : out std_logic
    );
end entity rle_decoder;

architecture rtl of rle_decoder is
    type state_t is (IDLE, ACCEPT_RUN, EXPAND_RUN, EMIT_BYTE);
    signal state : state_t := IDLE;

    signal cur_color   : std_logic := '0';
    signal rem_run     : integer range 0 to 255 := 0;
    signal col_accum   : integer range 0 to 128 := 0;
    signal row_idx     : integer range 0 to 64 := 0;
    signal byte_cnt    : integer range 0 to 1024 := 0;

    signal accum_byte  : std_logic_vector(7 downto 0) := (others => '0');
    signal bits_in_acc : integer range 0 to 7 := 0;

    signal was_last    : std_logic := '0';
    signal out_data_reg: std_logic_vector(7 downto 0) := (others => '0');
    signal out_val_reg : std_logic := '0';
    signal out_last_reg: std_logic := '0';

    signal sig_frame_done : std_logic := '0';
    signal sig_err_run    : std_logic := '0';
    signal sig_err_len    : std_logic := '0';
begin
    m_axis_data  <= out_data_reg;
    m_axis_valid <= out_val_reg;
    m_axis_last  <= out_last_reg;

    frame_done   <= sig_frame_done;
    err_run      <= sig_err_run;
    err_len      <= sig_err_len;

    s_axis_ready <= '1' when (state = ACCEPT_RUN) else '0';

    process(clk)
        variable needed : integer;
        variable fill   : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state          <= IDLE;
                cur_color      <= '0';
                rem_run        <= 0;
                col_accum      <= 0;
                row_idx        <= 0;
                byte_cnt       <= 0;
                accum_byte     <= (others => '0');
                bits_in_acc    <= 0;
                was_last       <= '0';
                out_data_reg   <= (others => '0');
                out_val_reg    <= '0';
                out_last_reg   <= '0';
                sig_frame_done <= '0';
                sig_err_run    <= '0';
                sig_err_len    <= '0';
            else
                -- Pulsa default 1-siklus
                sig_frame_done <= '0';
                sig_err_run    <= '0';
                sig_err_len    <= '0';

                -- Clear output valid saat di-handshake
                if out_val_reg = '1' and m_axis_ready = '1' then
                    out_val_reg  <= '0';
                    out_last_reg <= '0';
                end if;

                case state is
                    when IDLE =>
                        cur_color    <= '0';
                        rem_run      <= 0;
                        col_accum    <= 0;
                        row_idx      <= 0;
                        byte_cnt     <= 0;
                        accum_byte   <= (others => '0');
                        bits_in_acc  <= 0;
                        was_last     <= '0';
                        out_val_reg  <= '0';
                        out_last_reg <= '0';
                        state        <= ACCEPT_RUN;

                    when ACCEPT_RUN =>
                        if s_axis_valid = '1' then
                            was_last <= s_axis_last;
                            -- Validasi run length (maksimal 128 dan tidak melewati batas baris 128)
                            if to_integer(unsigned(s_axis_data)) > 128 or
                               (col_accum + to_integer(unsigned(s_axis_data)) > 128) then
                                sig_err_run <= '1';
                                state       <= IDLE;
                            else
                                rem_run <= to_integer(unsigned(s_axis_data));
                                state   <= EXPAND_RUN;
                            end if;
                        end if;

                    when EXPAND_RUN =>
                        if rem_run = 0 then
                            -- Run selesai: toggle warna
                            cur_color <= not cur_color;

                            if col_accum = 128 then
                                -- Baris selesai! Reset warna ke hitam untuk baris berikutnya
                                cur_color <= '0';
                                col_accum <= 0;
                                if row_idx = FRAME_HEIGHT - 1 then
                                    -- Frame penuh 64 baris selesai!
                                    if was_last = '1' and byte_cnt = TOTAL_BYTES then
                                        sig_frame_done <= '1';
                                    elsif was_last = '1' and byte_cnt /= TOTAL_BYTES then
                                        sig_err_len <= '1';
                                    end if;
                                    state <= IDLE;
                                else
                                    row_idx <= row_idx + 1;
                                    state   <= ACCEPT_RUN;
                                end if;
                            else
                                state <= ACCEPT_RUN;
                            end if;
                        else
                            -- Masih ada piksel yang harus dikemas ke byte kanonik
                            needed := 8 - bits_in_acc;
                            if rem_run >= needed then
                                fill := needed;
                            else
                                fill := rem_run;
                            end if;

                            -- Tulis bit cur_color ke posisi bit yang sesuai (MSB = piksel paling kiri)
                            for i in 0 to 7 loop
                                if i >= (7 - bits_in_acc - fill + 1) and i <= (7 - bits_in_acc) then
                                    accum_byte(i) <= cur_color;
                                end if;
                            end loop;

                            col_accum   <= col_accum + fill;
                            rem_run     <= rem_run - fill;
                            bits_in_acc <= bits_in_acc + fill;

                            if bits_in_acc + fill = 8 then
                                -- 1 byte kanonik lengkap (8 piksel)! Kirim ke EMIT_BYTE
                                state <= EMIT_BYTE;
                            end if;
                        end if;

                    when EMIT_BYTE =>
                        if out_val_reg = '0' or m_axis_ready = '1' then
                            out_data_reg <= accum_byte;
                            out_val_reg  <= '1';
                            byte_cnt     <= byte_cnt + 1;
                            accum_byte   <= (others => '0');
                            bits_in_acc  <= 0;

                            if byte_cnt + 1 = TOTAL_BYTES then
                                out_last_reg <= '1';
                            else
                                out_last_reg <= '0';
                            end if;

                            state <= EXPAND_RUN;
                        end if;
                end case;
            end if;
        end if;
    end process;

end architecture rtl;

