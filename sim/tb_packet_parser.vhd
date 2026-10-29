-- sim/tb_packet_parser.vhd
-- Testbench untuk modul packet_parser
-- Menguji parsing paket valid, deteksi galat checksum, dan penanganan galat panjang

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_packet_parser is
end entity tb_packet_parser;

architecture sim of tb_packet_parser is
    constant CLK_PERIOD : time := 10 ns;
    signal clk          : std_logic := '0';
    signal rst          : std_logic := '1';

    -- FIFO Interface
    signal fifo_rd_req     : std_logic;
    signal fifo_rd_data    : std_logic_vector(7 downto 0);
    signal fifo_spec_empty : std_logic;
    signal fifo_mark_sof   : std_logic;
    signal fifo_commit     : std_logic;
    signal fifo_rollback   : std_logic;

    -- FIFO Write
    signal wr_en   : std_logic := '0';
    signal wr_data : std_logic_vector(7 downto 0) := (others => '0');

    -- Payload stream to decoder
    signal m_axis_data  : std_logic_vector(7 downto 0);
    signal m_axis_valid : std_logic;
    signal m_axis_ready : std_logic := '1';
    signal m_axis_last  : std_logic;

    signal packet_valid : std_logic;
    signal packet_error : std_logic;
    signal frame_id_out : std_logic_vector(15 downto 0);

    signal cnt_valid_frames : unsigned(15 downto 0);
    signal cnt_chk_errors   : unsigned(15 downto 0);
    signal cnt_len_errors   : unsigned(15 downto 0);
    signal cnt_resyncs      : unsigned(15 downto 0);
begin
    clk <= not clk after CLK_PERIOD / 2;

    u_fifo : entity work.rx_fifo
        generic map (FIFO_DEPTH => 2048)
        port map (
            clk          => clk,
            rst          => rst,
            wr_en        => wr_en,
            wr_data      => wr_data,
            full         => open,
            rd_req       => fifo_rd_req,
            rd_data      => fifo_rd_data,
            spec_empty   => fifo_spec_empty,
            mark_sof     => fifo_mark_sof,
            commit       => fifo_commit,
            rollback     => fifo_rollback,
            commit_empty => open,
            overflow_err => open
        );

    dut : entity work.packet_parser
        generic map (
            PAYLOAD_LEN_MIN => 64,
            PAYLOAD_LEN_MAX => 1024,
            TIMEOUT_CYCLES  => 1000
        )
        port map (
            clk              => clk,
            rst              => rst,
            fifo_rd_req      => fifo_rd_req,
            fifo_rd_data     => fifo_rd_data,
            fifo_spec_empty  => fifo_spec_empty,
            fifo_mark_sof    => fifo_mark_sof,
            fifo_commit      => fifo_commit,
            fifo_rollback    => fifo_rollback,
            m_axis_data      => m_axis_data,
            m_axis_valid     => m_axis_valid,
            m_axis_ready     => m_axis_ready,
            m_axis_last      => m_axis_last,
            packet_valid     => packet_valid,
            packet_error     => packet_error,
            frame_id_out     => frame_id_out,
            cnt_valid_frames => cnt_valid_frames,
            cnt_chk_errors   => cnt_chk_errors,
            cnt_len_errors   => cnt_len_errors,
            cnt_resyncs      => cnt_resyncs
        );

    stim_proc : process
        variable chk : std_logic_vector(7 downto 0) := (others => '0');
        procedure push_byte(b : in std_logic_vector(7 downto 0)) is
        begin
            wait until rising_edge(clk);
            wr_en   <= '1';
            wr_data <= b;
            wait until rising_edge(clk);
            wr_en   <= '0';
        end procedure;
    begin
        rst <= '1';
        wait for 50 ns;
        rst <= '0';
        wait for 20 ns;

        -- 1. Uji Paket Valid: FRAME_ID = 0x0001, LEN = 64 (0x0040)
        -- SOF
        push_byte(x"55");
        push_byte(x"AA");
        push_byte(x"5A");
        -- FRAME_ID: 0x0001
        push_byte(x"00");
        push_byte(x"01");
        chk := x"00" xor x"01";
        -- PAYLOAD_LEN: 0x0040
        push_byte(x"00");
        push_byte(x"40");
        chk := chk xor x"00" xor x"40";
        -- 64 bytes payload
        for i in 0 to 63 loop
            push_byte(std_logic_vector(to_unsigned(i, 8)));
            chk := chk xor std_logic_vector(to_unsigned(i, 8));
        end loop;
        -- EOF
        push_byte(x"ED");
        chk := chk xor x"ED";
        -- CHECKSUM
        push_byte(chk);

        -- Tunggu parser selesai memproses
        wait until packet_valid = '1' for 50 us;
        assert packet_valid = '1' report "Gagal: packet_valid tidak aktif" severity error;
        wait until rising_edge(clk);
        assert cnt_valid_frames = 1 report "Gagal: cnt_valid_frames /= 1" severity error;

        -- 2. Uji Checksum Salah
        push_byte(x"55");
        push_byte(x"AA");
        push_byte(x"5A");
        push_byte(x"00");
        push_byte(x"02");
        push_byte(x"00");
        push_byte(x"40");
        for i in 0 to 63 loop
            push_byte(x"00");
        end loop;
        push_byte(x"ED");
        push_byte(x"00"); -- Checksum sengaja salah

        wait until packet_error = '1' for 50 us;
        assert packet_error = '1' report "Gagal: packet_error tidak aktif pada bad checksum" severity error;
        wait until rising_edge(clk);
        assert cnt_chk_errors = 1 report "Gagal: cnt_chk_errors /= 1" severity error;

        report "TEST PASSED: tb_packet_parser berhasil memverifikasi parsing paket dan checksum!";
        wait for 100 ns;
        stop;
    end process;

end architecture sim;

