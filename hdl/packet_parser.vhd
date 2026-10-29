-- hdl/packet_parser.vhd
-- FSM Parser Paket Streaming UART (Milestone M2)
-- Sesuai docs/PROTOCOL.md:
-- [SOF 3B: 0x55 0xAA 0x5A] [FRAME_ID 2B] [PAYLOAD_LEN 2B] [PAYLOAD N B] [EOF 1B: 0xED] [CHECKSUM 1B]
-- Mendukung verifikasi checksum, deteksi sinkron palsu, dan rollback pointer spekulatif.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity packet_parser is
    generic (
        PAYLOAD_LEN_MIN : integer := 64;
        PAYLOAD_LEN_MAX : integer := 1024;
        TIMEOUT_CYCLES  : integer := 5_000_000  -- 50 ms pada 100 MHz [DIASUMSIKAN]
    );
    port (
        clk               : in  std_logic;
        rst               : in  std_logic;

        -- Antarmuka FIFO RX Spekulatif
        fifo_rd_req       : out std_logic;
        fifo_rd_data      : in  std_logic_vector(7 downto 0);
        fifo_spec_empty   : in  std_logic;
        fifo_mark_sof     : out std_logic;
        fifo_commit       : out std_logic;
        fifo_rollback     : out std_logic;

        -- Aliran Payload ke Dekoder (AXI-Stream like)
        m_axis_data       : out std_logic_vector(7 downto 0);
        m_axis_valid      : out std_logic;
        m_axis_ready      : in  std_logic;
        m_axis_last       : out std_logic;

        -- Status & Sinyal Kontrol
        packet_valid      : out std_logic;
        packet_error      : out std_logic;
        frame_id_out      : out std_logic_vector(15 downto 0);

        -- Penghitung Kesalahan Hardware (untuk telemetri / testbench)
        cnt_valid_frames  : out unsigned(15 downto 0);
        cnt_chk_errors    : out unsigned(15 downto 0);
        cnt_len_errors    : out unsigned(15 downto 0);
        cnt_resyncs       : out unsigned(15 downto 0)
    );
end entity packet_parser;

architecture rtl of packet_parser is
    type state_t is (
        IDLE,
        FETCH_BYTE,
        LATCH_BYTE,
        HUNT_SOF_0,
        HUNT_SOF_1,
        HUNT_SOF_2,
        READ_FID_H,
        READ_FID_L,
        READ_LEN_H,
        READ_LEN_L,
        CHECK_LEN,
        DISPATCH_PAYLOAD,
        WAIT_PAYLOAD_READY,
        READ_EOF,
        READ_CHECKSUM
    );

    signal state       : state_t := IDLE;
    signal return_state: state_t := HUNT_SOF_0;

    signal cur_byte    : std_logic_vector(7 downto 0) := (others => '0');
    signal chk_accum   : std_logic_vector(7 downto 0) := (others => '0');

    signal frame_id_reg: std_logic_vector(15 downto 0) := (others => '0');
    signal len_reg     : std_logic_vector(15 downto 0) := (others => '0');
    signal payload_len : integer range 0 to 65535 := 0;
    signal bytes_left  : integer range 0 to 65535 := 0;

    signal timeout_cnt : integer range 0 to TIMEOUT_CYCLES := 0;

    -- Counter registers
    signal val_cnt : unsigned(15 downto 0) := (others => '0');
    signal chk_cnt : unsigned(15 downto 0) := (others => '0');
    signal len_cnt : unsigned(15 downto 0) := (others => '0');
    signal res_cnt : unsigned(15 downto 0) := (others => '0');

    signal had_garbage : std_logic := '0';
begin
    frame_id_out     <= frame_id_reg;
    cnt_valid_frames <= val_cnt;
    cnt_chk_errors   <= chk_cnt;
    cnt_len_errors   <= len_cnt;
    cnt_resyncs      <= res_cnt;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state         <= IDLE;
                return_state  <= HUNT_SOF_0;
                fifo_rd_req   <= '0';
                fifo_mark_sof <= '0';
                fifo_commit   <= '0';
                fifo_rollback <= '0';
                m_axis_data   <= (others => '0');
                m_axis_valid  <= '0';
                m_axis_last   <= '0';
                packet_valid  <= '0';
                packet_error  <= '0';
                frame_id_reg  <= (others => '0');
                payload_len   <= 0;
                bytes_left    <= 0;
                timeout_cnt   <= 0;
                val_cnt       <= (others => '0');
                chk_cnt       <= (others => '0');
                len_cnt       <= (others => '0');
                res_cnt       <= (others => '0');
                had_garbage   <= '0';
            else
                -- Pulsa default 1-siklus
                fifo_rd_req   <= '0';
                fifo_mark_sof <= '0';
                fifo_commit   <= '0';
                fifo_rollback <= '0';
                packet_valid  <= '0';
                packet_error  <= '0';

                -- Timeout watchdog untuk paket yang terpotong di tengah jalan
                if (return_state >= READ_FID_H and return_state <= READ_CHECKSUM) or 
                   (state >= READ_FID_H and state <= READ_CHECKSUM) then
                    if fifo_spec_empty = '1' then
                        if timeout_cnt = TIMEOUT_CYCLES then
                            timeout_cnt   <= 0;
                            packet_error  <= '1';
                            len_cnt       <= len_cnt + 1;
                            fifo_rollback <= '1';
                            return_state  <= HUNT_SOF_0;
                            state         <= IDLE;
                        else
                            timeout_cnt <= timeout_cnt + 1;
                        end if;
                    else
                        timeout_cnt <= 0;
                    end if;
                else
                    timeout_cnt <= 0;
                end if;

                case state is
                    when IDLE =>
                        m_axis_valid <= '0';
                        m_axis_last  <= '0';
                        if fifo_spec_empty = '0' then
                            fifo_rd_req <= '1';
                            state       <= LATCH_BYTE;
                        end if;

                    when FETCH_BYTE =>
                        m_axis_valid <= '0';
                        m_axis_last  <= '0';
                        if fifo_spec_empty = '0' then
                            fifo_rd_req <= '1';
                            state       <= LATCH_BYTE;
                        end if;

                    when LATCH_BYTE =>
                        -- Latensi 1-siklus BRAM telah terpenuhi
                        cur_byte <= fifo_rd_data;
                        state    <= return_state;

                    -- 1. Deteksi Pola SOF: 0x55, 0xAA, 0x5A
                    when HUNT_SOF_0 =>
                        if cur_byte = x"55" then
                            return_state <= HUNT_SOF_1;
                            state        <= FETCH_BYTE;
                        else
                            -- Byte bukan 0x55 (sampah di awal stream)
                            had_garbage  <= '1';
                            return_state <= HUNT_SOF_0;
                            state        <= FETCH_BYTE;
                        end if;

                    when HUNT_SOF_1 =>
                        if cur_byte = x"AA" then
                            return_state <= HUNT_SOF_2;
                            state        <= FETCH_BYTE;
                        elsif cur_byte = x"55" then
                            -- Karakter berulang 0x55 0x55, tetap tunggu 0xAA
                            return_state <= HUNT_SOF_1;
                            state        <= FETCH_BYTE;
                        else
                            had_garbage  <= '1';
                            return_state <= HUNT_SOF_0;
                            state        <= FETCH_BYTE;
                        end if;

                    when HUNT_SOF_2 =>
                        if cur_byte = x"5A" then
                            -- SOF lengkap terdeteksi!
                            fifo_mark_sof <= '1';
                            chk_accum     <= (others => '0');
                            if had_garbage = '1' then
                                res_cnt     <= res_cnt + 1;
                                had_garbage <= '0';
                            end if;
                            return_state  <= READ_FID_H;
                            state         <= FETCH_BYTE;
                        elsif cur_byte = x"55" then
                            return_state <= HUNT_SOF_1;
                            state        <= FETCH_BYTE;
                        else
                            had_garbage  <= '1';
                            return_state <= HUNT_SOF_0;
                            state        <= FETCH_BYTE;
                        end if;

                    -- 2. Pembacaan Header: FRAME_ID (2B) & PAYLOAD_LEN (2B)
                    when READ_FID_H =>
                        frame_id_reg(15 downto 8) <= cur_byte;
                        chk_accum                 <= chk_accum xor cur_byte;
                        return_state              <= READ_FID_L;
                        state                     <= FETCH_BYTE;

                    when READ_FID_L =>
                        frame_id_reg(7 downto 0) <= cur_byte;
                        chk_accum                <= chk_accum xor cur_byte;
                        return_state             <= READ_LEN_H;
                        state                    <= FETCH_BYTE;

                    when READ_LEN_H =>
                        len_reg(15 downto 8) <= cur_byte;
                        chk_accum            <= chk_accum xor cur_byte;
                        return_state         <= READ_LEN_L;
                        state                <= FETCH_BYTE;

                    when READ_LEN_L =>
                        len_reg(7 downto 0) <= cur_byte;
                        chk_accum           <= chk_accum xor cur_byte;
                        payload_len         <= to_integer(unsigned(len_reg(15 downto 8) & cur_byte));
                        state               <= CHECK_LEN;

                    when CHECK_LEN =>
                        -- Validasi Batas Panjang Payload (64 .. 1024)
                        if payload_len < PAYLOAD_LEN_MIN or payload_len > PAYLOAD_LEN_MAX then
                            -- Sinkron palsu / ukuran tidak valid!
                            len_cnt       <= len_cnt + 1;
                            res_cnt       <= res_cnt + 1;
                            packet_error  <= '1';
                            fifo_rollback <= '1';
                            return_state  <= HUNT_SOF_0;
                            state         <= IDLE;
                        else
                            bytes_left   <= payload_len;
                            return_state <= DISPATCH_PAYLOAD;
                            state        <= FETCH_BYTE;
                        end if;

                    -- 3. Penyaluran Payload ke Dekoder RLE
                    when DISPATCH_PAYLOAD =>
                        m_axis_data  <= cur_byte;
                        m_axis_valid <= '1';
                        if bytes_left = 1 then
                            m_axis_last <= '1';
                        else
                            m_axis_last <= '0';
                        end if;
                        state <= WAIT_PAYLOAD_READY;

                    when WAIT_PAYLOAD_READY =>
                        if m_axis_ready = '1' then
                            m_axis_valid <= '0';
                            m_axis_last  <= '0';
                            chk_accum    <= chk_accum xor cur_byte;

                            if bytes_left = 1 then
                                -- Seluruh payload selesai disalurkan, baca EOF
                                return_state <= READ_EOF;
                                state        <= FETCH_BYTE;
                            else
                                bytes_left   <= bytes_left - 1;
                                return_state <= DISPATCH_PAYLOAD;
                                state        <= FETCH_BYTE;
                            end if;
                        end if;

                    -- 4. Verifikasi EOF (0xED)
                    when READ_EOF =>
                        if cur_byte /= x"ED" then
                            -- EOF salah -> sinkron palsu / paket cacat
                            len_cnt       <= len_cnt + 1;
                            res_cnt       <= res_cnt + 1;
                            packet_error  <= '1';
                            fifo_rollback <= '1';
                            return_state  <= HUNT_SOF_0;
                            state         <= IDLE;
                        else
                            chk_accum    <= chk_accum xor x"ED";
                            return_state <= READ_CHECKSUM;
                            state        <= FETCH_BYTE;
                        end if;

                    -- 5. Verifikasi Checksum (XOR)
                    when READ_CHECKSUM =>
                        if cur_byte = chk_accum then
                            -- Paket 100% Valid!
                            packet_valid <= '1';
                            fifo_commit  <= '1';
                            val_cnt      <= val_cnt + 1;
                            had_garbage  <= '0';
                            return_state <= HUNT_SOF_0;
                            state        <= IDLE;
                        else
                            -- Checksum mismatch!
                            chk_cnt       <= chk_cnt + 1;
                            packet_error  <= '1';
                            fifo_rollback <= '1';
                            return_state  <= HUNT_SOF_0;
                            state         <= IDLE;
                        end if;
                end case;
            end if;
        end if;
    end process;

end architecture rtl;

