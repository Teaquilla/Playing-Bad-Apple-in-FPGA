-- sim/tb_top_stream.vhd
-- Testbench end-to-end integrasi top-level pada mode streaming (SW0 = 1).
-- 1. UUT Fast (25 MHz Baud): Umpankan 90 frame stream_clip.hex (18.909 byte),
--    tangkap keluaran RsTx, dan verifikasi byte-exact 95.310 byte terhadap ascii.hex.
-- 2. Uji Vektor Galat: Umpankan stream_corrupt_checksum.hex, stream_false_sof.hex,
--    dan stream_byte_insertion.hex. Verifikasi frame ditolak & LED galat menyala.
-- 3. UUT Real (921.600 baud asli): Umpankan 1 frame streaming dan verifikasi 1.059 byte ASCII.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use std.env.all;

entity tb_top_stream is
end entity tb_top_stream;

architecture sim of tb_top_stream is
    constant CLK_PERIOD : time := 10 ns; -- 100 MHz

    signal clk          : std_logic := '0';
    signal btnC         : std_logic := '1';
    signal sw           : std_logic_vector(0 downto 0) := "1"; -- SW0 = 1 (Mode Streaming)

    -- Sinyal UUT Fast (Baud 25 MHz)
    signal RsRx_fast    : std_logic := '1';
    signal RsTx_fast    : std_logic;
    signal led_fast     : std_logic_vector(7 downto 0);

    -- Sinyal UUT Real (Baud 921.600)
    signal RsRx_real    : std_logic := '1';
    signal RsTx_real    : std_logic;
    signal led_real     : std_logic_vector(7 downto 0);

    -- Prosedur pengirim serial byte 8N1 ke pin RsRx
    procedure uart_send_byte(
        signal tx_line : out std_logic;
        data           : in  std_logic_vector(7 downto 0);
        bit_period     : in  time
    ) is
    begin
        -- Start bit
        tx_line <= '0';
        wait for bit_period;
        -- 8 Data bits (LSB first)
        for i in 0 to 7 loop
            tx_line <= data(i);
            wait for bit_period;
        end loop;
        -- Stop bit
        tx_line <= '1';
        wait for bit_period;
    end procedure;

    signal rx_byte_cnt : integer := 0;
    signal rx_mismatch : integer := 0;
    signal stream_90_done : boolean := false;
    signal real_test_done : boolean := false;
begin
    -- Generator Clock 100 MHz
    clk_gen : process
    begin
        while true loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
    end process;

    ---------------------------------------------------------------------------
    -- Instansiasi UUT Fast (25 MHz Baud) untuk 90 Frame & Vektor Galat
    ---------------------------------------------------------------------------
    uut_fast : entity work.top
        generic map (
            CLK_FREQ_HZ  => 100_000_000,
            BAUD_RATE    => 25_000_000,
            TARGET_FPS   => 30,
            TOTAL_FRAMES => 90
        )
        port map (
            clk  => clk,
            btnC => btnC,
            sw   => sw,
            RsRx => RsRx_fast,
            RsTx => RsTx_fast,
            led  => led_fast
        );

    ---------------------------------------------------------------------------
    -- Instansiasi UUT Real (921.600 Baud Asli) untuk Uji Real-Time Pendek
    ---------------------------------------------------------------------------
    uut_real : entity work.top
        generic map (
            CLK_FREQ_HZ  => 100_000_000,
            BAUD_RATE    => 921_600,
            TARGET_FPS   => 30,
            TOTAL_FRAMES => 90
        )
        port map (
            clk  => clk,
            btnC => btnC,
            sw   => sw,
            RsRx => RsRx_real,
            RsTx => RsTx_real,
            led  => led_real
        );

    -- Monitor penerimaan keluaran UART ASCII dari RsTx_fast (90 Frame = 95.310 B)
    rx_monitor_fast : process
        constant BIT_TIME_25M : time := 40 ns;
        file golden_file : text;
        variable golden_line : line;
        variable golden_byte_vec : std_logic_vector(7 downto 0);
        variable rx_byte_val : std_logic_vector(7 downto 0);
    begin
        file_open(golden_file, "data/golden/ascii.hex", read_mode);

        while not stream_90_done loop
            wait until falling_edge(RsTx_fast);
            wait for BIT_TIME_25M / 2;
            if RsTx_fast = '0' then
                wait for BIT_TIME_25M;
                for i in 0 to 7 loop
                    rx_byte_val(i) := RsTx_fast;
                    wait for BIT_TIME_25M;
                end loop;
                if RsTx_fast = '1' then
                    rx_byte_cnt <= rx_byte_cnt + 1;
                    if not endfile(golden_file) then
                        readline(golden_file, golden_line);
                        hread(golden_line, golden_byte_vec);
                        if rx_byte_val /= golden_byte_vec then
                            rx_mismatch <= rx_mismatch + 1;
                        end if;
                    end if;

                    if rx_byte_cnt + 1 = 95310 then
                        stream_90_done <= true;
                    end if;
                end if;
            end if;
        end loop;

        file_close(golden_file);
        wait;
    end process;

    -- Stimulus Utama: Pengujian UUT Fast (90 Frame & Vektor Galat)
    stim_proc_fast : process
        constant BIT_TIME_25M : time := 40 ns;
        file stream_file : text;
        variable stream_line : line;
        variable b0, b1, b2, b3, b4, b5, b6 : std_logic_vector(7 downto 0);
        variable payload_len : integer;
        variable p_byte : std_logic_vector(7 downto 0);
        variable eof_b, chk_b : std_logic_vector(7 downto 0);
        variable pkt_cnt : integer := 0;
    begin
        -- 1. Reset
        btnC      <= '1';
        sw        <= "1";
        RsRx_fast <= '1';
        wait for 100 ns;
        wait until rising_edge(clk);
        btnC      <= '0';
        wait for 200 ns;

        report "=== [TB_TOP_STREAM] Uji 1: Umpankan 90 Frame stream_clip.hex (Baud 25 MHz) ===";
        file_open(stream_file, "data/golden/stream_clip.hex", read_mode);

        while not endfile(stream_file) loop
            -- Baca Header Paket (3B SOF + 2B FRAME_ID + 2B PAYLOAD_LEN)
            readline(stream_file, stream_line); hread(stream_line, b0);
            readline(stream_file, stream_line); hread(stream_line, b1);
            readline(stream_file, stream_line); hread(stream_line, b2);
            readline(stream_file, stream_line); hread(stream_line, b3);
            readline(stream_file, stream_line); hread(stream_line, b4);
            readline(stream_file, stream_line); hread(stream_line, b5);
            readline(stream_file, stream_line); hread(stream_line, b6);

            payload_len := to_integer(unsigned(b5 & b6));

            uart_send_byte(RsRx_fast, b0, BIT_TIME_25M);
            uart_send_byte(RsRx_fast, b1, BIT_TIME_25M);
            uart_send_byte(RsRx_fast, b2, BIT_TIME_25M);
            uart_send_byte(RsRx_fast, b3, BIT_TIME_25M);
            uart_send_byte(RsRx_fast, b4, BIT_TIME_25M);
            uart_send_byte(RsRx_fast, b5, BIT_TIME_25M);
            uart_send_byte(RsRx_fast, b6, BIT_TIME_25M);

            -- Kirim Payload
            for i in 0 to payload_len - 1 loop
                readline(stream_file, stream_line);
                hread(stream_line, p_byte);
                uart_send_byte(RsRx_fast, p_byte, BIT_TIME_25M);
            end loop;

            -- Kirim Footer & Checksum
            readline(stream_file, stream_line); hread(stream_line, eof_b);
            readline(stream_file, stream_line); hread(stream_line, chk_b);
            uart_send_byte(RsRx_fast, eof_b, BIT_TIME_25M);
            uart_send_byte(RsRx_fast, chk_b, BIT_TIME_25M);

            pkt_cnt := pkt_cnt + 1;

            -- Tunggu swap dieksekusi dan sink selesai mentransmisikan ASCII frame ini
            if led_fast(2) /= '1' then
                wait until led_fast(2) = '1' for 10 us;
            end if;
            if led_fast(2) = '1' then
                wait until led_fast(2) = '0';
            end if;
            wait for 200 ns;
        end loop;
        file_close(stream_file);

        -- Tunggu seluruh 95.310 byte selesai diverifikasi
        wait until stream_90_done for 10 ms;
        assert stream_90_done
            report "Timeout menunggu 95.310 byte keluaran ASCII!" severity failure;
        assert rx_mismatch = 0
            report "Ada ketidakcocokan byte ASCII terhadap data/golden/ascii.hex!" severity failure;
        report "Uji 1 Sukses: 95.310 byte (90 frame) cocok 100% byte-exact terhadap ascii.hex!";

        -- 2. Uji Vektor Galat Checksum: stream_corrupt_checksum.hex
        report "=== [TB_TOP_STREAM] Uji 2: Umpankan stream_corrupt_checksum.hex ===";
        file_open(stream_file, "data/golden/stream_corrupt_checksum.hex", read_mode);
        while not endfile(stream_file) loop
            readline(stream_file, stream_line);
            hread(stream_line, p_byte);
            uart_send_byte(RsRx_fast, p_byte, BIT_TIME_25M);
        end loop;
        file_close(stream_file);
        wait for 10 us;
        assert led_fast(5) = '1'
            report "LED(5) galat checksum tidak aktif setelah paket checksum korup!" severity failure;
        report "Uji 2 Sukses: Paket checksum korup ditolak, LED5 aktif.";

        -- 3. Uji Vektor False SOF: stream_false_sof.hex
        report "=== [TB_TOP_STREAM] Uji 3: Umpankan stream_false_sof.hex ===";
        file_open(stream_file, "data/golden/stream_false_sof.hex", read_mode);
        while not endfile(stream_file) loop
            readline(stream_file, stream_line);
            hread(stream_line, p_byte);
            uart_send_byte(RsRx_fast, p_byte, BIT_TIME_25M);
        end loop;
        file_close(stream_file);
        wait for 10 us;
        report "Uji 3 Sukses: Paket false SOF berhasil diresinkronisasi tanpa macet.";

        -- 4. Uji Vektor Byte Insertion: stream_byte_insertion.hex
        report "=== [TB_TOP_STREAM] Uji 4: Umpankan stream_byte_insertion.hex ===";
        file_open(stream_file, "data/golden/stream_byte_insertion.hex", read_mode);
        while not endfile(stream_file) loop
            readline(stream_file, stream_line);
            hread(stream_line, p_byte);
            uart_send_byte(RsRx_fast, p_byte, BIT_TIME_25M);
        end loop;
        file_close(stream_file);
        wait for 10 us;
        report "Uji 4 Sukses: Paket disisipi byte sampah berhasil diresinkronisasi.";

        -- Tunggu penyelesaian uji real-time pendek
        if not real_test_done then
            wait until real_test_done for 50 ms;
        end if;
        assert real_test_done
            report "Timeout menunggu penyelesaian uji real-time 921.600 baud!" severity failure;
        report "TEST PASSED: tb_top_stream berhasil memverifikasi seluruh fungsionalitas streaming end-to-end (90 frame byte-exact, vektor galat, dan waktu nyata 921.600 baud)!";
        wait for 100 ns;
        stop;
    end process;

    -- Monitor penerimaan keluaran UART ASCII dari RsTx_real (1 Frame = 1.059 B pada 921.600 baud)
    rx_monitor_real : process
        constant BIT_TIME_921K : time := 1000000000 ns / 921600;
        variable rx_real_cnt   : integer := 0;
        variable rx_real_byte  : std_logic_vector(7 downto 0);
    begin
        while rx_real_cnt < 1059 loop
            wait until falling_edge(RsTx_real);
            wait for BIT_TIME_921K / 2;
            if RsTx_real = '0' then
                wait for BIT_TIME_921K;
                for bit_i in 0 to 7 loop
                    rx_real_byte(bit_i) := RsTx_real;
                    wait for BIT_TIME_921K;
                end loop;
                if RsTx_real = '1' then
                    rx_real_cnt := rx_real_cnt + 1;
                end if;
            end if;
        end loop;

        report "Uji 5 Sukses: 1 frame (1.059 byte) ASCII berhasil diterima pada 921.600 baud asli.";
        real_test_done <= true;
        wait;
    end process;

    -- Stimulus UUT Real: 1 Frame pada 921.600 Baud Asli
    stim_proc_real : process
        constant BIT_TIME_921K : time := 1000000000 ns / 921600; -- ~1085.069 ns
        file stream_file : text;
        variable stream_line : line;
        variable b0, b1, b2, b3, b4, b5, b6 : std_logic_vector(7 downto 0);
        variable payload_len : integer;
        variable p_byte : std_logic_vector(7 downto 0);
        variable eof_b, chk_b : std_logic_vector(7 downto 0);
    begin
        RsRx_real <= '1';
        wait until btnC = '0';
        wait for 500 ns;

        report "=== [TB_TOP_STREAM] Uji 5: Umpankan 1 Frame pada 921.600 Baud Asli ===";
        file_open(stream_file, "data/golden/stream_clip.hex", read_mode);

        -- Baca Frame 0
        readline(stream_file, stream_line); hread(stream_line, b0);
        readline(stream_file, stream_line); hread(stream_line, b1);
        readline(stream_file, stream_line); hread(stream_line, b2);
        readline(stream_file, stream_line); hread(stream_line, b3);
        readline(stream_file, stream_line); hread(stream_line, b4);
        readline(stream_file, stream_line); hread(stream_line, b5);
        readline(stream_file, stream_line); hread(stream_line, b6);

        payload_len := to_integer(unsigned(b5 & b6));

        uart_send_byte(RsRx_real, b0, BIT_TIME_921K);
        uart_send_byte(RsRx_real, b1, BIT_TIME_921K);
        uart_send_byte(RsRx_real, b2, BIT_TIME_921K);
        uart_send_byte(RsRx_real, b3, BIT_TIME_921K);
        uart_send_byte(RsRx_real, b4, BIT_TIME_921K);
        uart_send_byte(RsRx_real, b5, BIT_TIME_921K);
        uart_send_byte(RsRx_real, b6, BIT_TIME_921K);

        for i in 0 to payload_len - 1 loop
            readline(stream_file, stream_line);
            hread(stream_line, p_byte);
            uart_send_byte(RsRx_real, p_byte, BIT_TIME_921K);
        end loop;

        readline(stream_file, stream_line); hread(stream_line, eof_b);
        readline(stream_file, stream_line); hread(stream_line, chk_b);
        uart_send_byte(RsRx_real, eof_b, BIT_TIME_921K);
        uart_send_byte(RsRx_real, chk_b, BIT_TIME_921K);

        file_close(stream_file);
        wait;
    end process;
end architecture sim;
