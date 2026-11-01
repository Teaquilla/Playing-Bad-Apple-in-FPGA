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

    signal rx_byte_cnt    : integer := 0;
    signal rx_mismatch    : integer := 0;
    signal stream_90_done : boolean := false;

    signal uji3_start     : boolean := false;
    signal uji3_byte_cnt  : integer := 0;
    signal uji3_mismatch  : integer := 0;
    signal uji3_done      : boolean := false;

    signal uji4_start     : boolean := false;
    signal uji4_byte_cnt  : integer := 0;
    signal uji4_mismatch  : integer := 0;
    signal uji4_done      : boolean := false;

    signal uji3_stop      : boolean := false;
    signal uji4_stop      : boolean := false;
    signal real_stop      : boolean := false;

    signal real_byte_cnt  : integer := 0;
    signal real_mismatch  : integer := 0;
    signal real_test_done : boolean := false;
    signal rle_err_run_cnt: integer := 0;
    alias rle_err_run_fast is << signal .tb_top_stream.uut_fast.rle_err_run : std_logic >>;
begin
    -- Monitor akumulasi galat run RLE
    process(clk)
    begin
        if rising_edge(clk) then
            if rle_err_run_fast = '1' then
                rle_err_run_cnt <= rle_err_run_cnt + 1;
            end if;
        end if;
    end process;

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

    -- Monitor penerimaan keluaran UART ASCII dari RsTx_fast untuk Frame 0 pada Uji 3
    rx_monitor_uji3 : process
        constant BIT_TIME_25M : time := 40 ns;
        file gold_file : text;
        variable gold_line : line;
        variable gold_byte : std_logic_vector(7 downto 0);
        variable rx_val : std_logic_vector(7 downto 0);
        variable cnt : integer := 0;
        variable mism : integer := 0;
    begin
        wait until uji3_start;
        file_open(gold_file, "data/golden/ascii.hex", read_mode);
        while not uji3_stop loop
            wait until falling_edge(RsTx_fast) or uji3_stop;
            if uji3_stop then
                exit;
            end if;
            wait for BIT_TIME_25M / 2;
            if RsTx_fast = '0' then
                wait for BIT_TIME_25M;
                for bit_i in 0 to 7 loop
                    rx_val(bit_i) := RsTx_fast;
                    wait for BIT_TIME_25M;
                end loop;
                if RsTx_fast = '1' then
                    cnt := cnt + 1;
                    uji3_byte_cnt <= cnt;
                    if cnt <= 1059 and not endfile(gold_file) then
                        readline(gold_file, gold_line);
                        hread(gold_line, gold_byte);
                        if rx_val /= gold_byte then
                            mism := mism + 1;
                        end if;
                    end if;
                    if cnt = 1059 then
                        uji3_done <= true;
                    end if;
                end if;
            end if;
        end loop;
        file_close(gold_file);

        uji3_mismatch <= mism;
        wait;
    end process;

    -- Monitor penerimaan keluaran UART ASCII dari RsTx_fast untuk Frame 0 pada Uji 4
    rx_monitor_uji4 : process
        constant BIT_TIME_25M : time := 40 ns;
        file gold_file : text;
        variable gold_line : line;
        variable gold_byte : std_logic_vector(7 downto 0);
        variable rx_val : std_logic_vector(7 downto 0);
        variable cnt : integer := 0;
        variable mism : integer := 0;
    begin
        wait until uji4_start;
        file_open(gold_file, "data/golden/ascii.hex", read_mode);
        while not uji4_stop loop
            wait until falling_edge(RsTx_fast) or uji4_stop;
            if uji4_stop then
                exit;
            end if;
            wait for BIT_TIME_25M / 2;
            if RsTx_fast = '0' then
                wait for BIT_TIME_25M;
                for bit_i in 0 to 7 loop
                    rx_val(bit_i) := RsTx_fast;
                    wait for BIT_TIME_25M;
                end loop;
                if RsTx_fast = '1' then
                    cnt := cnt + 1;
                    uji4_byte_cnt <= cnt;
                    if cnt <= 1059 and not endfile(gold_file) then
                        readline(gold_file, gold_line);
                        hread(gold_line, gold_byte);
                        if rx_val /= gold_byte then
                            mism := mism + 1;
                        end if;
                    end if;
                    if cnt = 1059 then
                        uji4_done <= true;
                    end if;
                end if;
            end if;
        end loop;
        file_close(gold_file);

        uji4_mismatch <= mism;
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
        alias err_chk_cnt_fast is << signal .tb_top_stream.uut_fast.err_checksum_cnt : unsigned(15 downto 0) >>;
        alias val_cnt_fast     is << signal .tb_top_stream.uut_fast.u_parser.val_cnt : unsigned(15 downto 0) >>;
        alias err_len_cnt_fast is << signal .tb_top_stream.uut_fast.err_length_cnt : unsigned(15 downto 0) >>;
        alias err_res_cnt_fast is << signal .tb_top_stream.uut_fast.err_resync_cnt : unsigned(15 downto 0) >>;
        alias fb_swap_done_fast is << signal .tb_top_stream.uut_fast.fb_swap_done : std_logic >>;
        variable err_chk_before : integer;
        variable rx_cnt_before  : integer;
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
        -- Verifikasi kriteria stream_expected.txt untuk stream_clip: valid frames = 90, seluruh error counter = 0
        assert to_integer(val_cnt_fast) = 90
            report "Uji 1: Jumlah valid frame bukan 90 (terbaca: " & integer'image(to_integer(val_cnt_fast)) & ")!" severity failure;
        assert to_integer(err_chk_cnt_fast) = 0 and to_integer(err_len_cnt_fast) = 0 and to_integer(err_res_cnt_fast) = 0
            report "Uji 1: Error counter tidak nol (chk=" & integer'image(to_integer(err_chk_cnt_fast)) &
                   ", len=" & integer'image(to_integer(err_len_cnt_fast)) &
                   ", res=" & integer'image(to_integer(err_res_cnt_fast)) & ")!" severity failure;
        report "Uji 1 Sukses: 95.310 byte (90 frame) cocok 100% byte-exact terhadap ascii.hex, valid_frames=90, errors=0.";

        -- 2. Uji Vektor Galat Checksum: stream_corrupt_checksum.hex
        report "=== [TB_TOP_STREAM] Uji 2: Umpankan stream_corrupt_checksum.hex ===";
        err_chk_before := to_integer(err_chk_cnt_fast);
        rx_cnt_before  := rx_byte_cnt;

        file_open(stream_file, "data/golden/stream_corrupt_checksum.hex", read_mode);
        while not endfile(stream_file) loop
            readline(stream_file, stream_line);
            hread(stream_line, p_byte);
            uart_send_byte(RsRx_fast, p_byte, BIT_TIME_25M);
        end loop;
        file_close(stream_file);
        wait for 10 us;

        -- Verifikasi kriteria stream_expected.txt untuk stream_corrupt_checksum: chk_errors bertambah 1, valid_frames tetap 90
        assert to_integer(err_chk_cnt_fast) = err_chk_before + 1
            report "cnt_chk_errors tidak bertambah 1 setelah stream_corrupt_checksum!" severity failure;
        assert to_integer(val_cnt_fast) = 90
            report "Uji 2: valid_frames bertambah saat paket korup!" severity failure;
        assert led_fast(5) = '1'
            report "LED(5) galat checksum tidak aktif setelah paket checksum korup!" severity failure;
        assert rx_byte_cnt = rx_cnt_before
            report "ascii_sink mentransmisikan data saat paket korup (frame_buffer swap ilegal)!" severity failure;
        report "Uji 2 Sukses: Paket checksum korup ditolak, err_chk_cnt bertambah 1, frame_buffer tidak swap, LED5 aktif.";

        -- 3. Uji Vektor False SOF: stream_false_sof.hex (fake SOF + Frame 0 = 372 byte)
        report "=== [TB_TOP_STREAM] Uji 3: Umpankan stream_false_sof.hex ===";
        uji3_start <= true;
        file_open(stream_file, "data/golden/stream_false_sof.hex", read_mode);
        for i in 1 to 372 loop
            readline(stream_file, stream_line);
            hread(stream_line, p_byte);
            uart_send_byte(RsRx_fast, p_byte, BIT_TIME_25M);
        end loop;
        file_close(stream_file);
        if not uji3_done then
            wait until uji3_done for 5 ms;
        end if;
        assert uji3_done
            report "Timeout menunggu 1.059 byte Frame 0 ASCII pada Uji 3!" severity failure;
        assert uji3_mismatch = 0
            report "Ada ketidakcocokan byte ASCII pada Uji 3 terhadap Frame 0 ascii.hex!" severity failure;
        -- Verifikasi tidak ada byte ASCII ekstra setelah 1.059 byte (tunggu >= 2 periode frame = 1 ms)
        wait for 1 ms;
        assert uji3_byte_cnt = 1059
            report "Ada byte ASCII ekstra setelah 1.059 byte pada Uji 3 (terhitung: " & integer'image(uji3_byte_cnt) & ")!" severity failure;
        uji3_stop <= true;
        if led_fast(2) = '1' then
            wait until led_fast(2) = '0';
        end if;
        wait for 1 us;
        -- Verifikasi metrik stream_expected.txt untuk stream_false_sof:
        -- VALID_FRAMES bertambah 1 (Frame 0), LENGTH_ERRORS bertambah 1 (false SOF terdeteksi via length/timeout err),
        -- CHECKSUM_ERRORS tetap 1, RUN_ERRORS tetap 0, RESYNCS bertambah (resync SOF asli).
        assert to_integer(val_cnt_fast) = 91
            report "Uji 3: valid_frames bukan 91 (terbaca: " & integer'image(to_integer(val_cnt_fast)) & ")!" severity failure;
        assert to_integer(err_chk_cnt_fast) = 1
            report "Uji 3: chk_errors bukan 1 (terbaca: " & integer'image(to_integer(err_chk_cnt_fast)) & ")!" severity failure;
        assert to_integer(err_len_cnt_fast) = 1
            report "Uji 3: len_errors bukan 1 (terbaca: " & integer'image(to_integer(err_len_cnt_fast)) & ")!" severity failure;
        assert rle_err_run_cnt = 0
            report "Uji 3: run_errors bukan 0!" severity failure;
        assert to_integer(err_res_cnt_fast) = 3
            report "Uji 3: resyncs bukan 3 (terbaca: " & integer'image(to_integer(err_res_cnt_fast)) & ")!" severity failure;
        report "Uji 3 Sukses: Paket false SOF berhasil diresinkronisasi dan Frame 0 byte-exact (1.059 B, val=91, chk=1, len=1, run=0, res=3)!";

        -- 4. Uji Vektor Byte Insertion: stream_byte_insertion.hex (garbage 6B + Frame 0 347B = 353 byte)
        report "=== [TB_TOP_STREAM] Uji 4: Umpankan stream_byte_insertion.hex ===";
        uji4_start <= true;
        file_open(stream_file, "data/golden/stream_byte_insertion.hex", read_mode);
        for i in 1 to 353 loop
            readline(stream_file, stream_line);
            hread(stream_line, p_byte);
            uart_send_byte(RsRx_fast, p_byte, BIT_TIME_25M);
        end loop;
        file_close(stream_file);
        if not uji4_done then
            wait until uji4_done for 5 ms;
        end if;
        assert uji4_done
            report "Timeout menunggu 1.059 byte Frame 0 ASCII pada Uji 4!" severity failure;
        assert uji4_mismatch = 0
            report "Ada ketidakcocokan byte ASCII pada Uji 4 terhadap Frame 0 ascii.hex!" severity failure;
        -- Verifikasi tidak ada byte ASCII ekstra setelah 1.059 byte (tunggu >= 2 periode frame = 1 ms)
        wait for 1 ms;
        assert uji4_byte_cnt = 1059
            report "Ada byte ASCII ekstra setelah 1.059 byte pada Uji 4 (terhitung: " & integer'image(uji4_byte_cnt) & ")!" severity failure;
        uji4_stop <= true;
        if led_fast(2) = '1' then
            wait until led_fast(2) = '0';
        end if;
        wait for 1 us;
        -- Verifikasi metrik stream_expected.txt untuk stream_byte_insertion:
        -- VALID_FRAMES bertambah 1 (Frame 0), RESYNCS bertambah 1 (sampah 6B sebelum SOF),
        -- CHECKSUM_ERRORS tetap 1, LENGTH_ERRORS tetap 1, RUN_ERRORS tetap 0.
        assert to_integer(val_cnt_fast) = 92
            report "Uji 4: valid_frames bukan 92 (terbaca: " & integer'image(to_integer(val_cnt_fast)) & ")!" severity failure;
        assert to_integer(err_chk_cnt_fast) = 1
            report "Uji 4: chk_errors bukan 1!" severity failure;
        assert to_integer(err_len_cnt_fast) = 1
            report "Uji 4: len_errors bukan 1!" severity failure;
        assert rle_err_run_cnt = 0
            report "Uji 4: run_errors bukan 0!" severity failure;
        assert to_integer(err_res_cnt_fast) = 4
            report "Uji 4: resyncs bukan 4 (terbaca: " & integer'image(to_integer(err_res_cnt_fast)) & ")!" severity failure;
        report "Uji 4 Sukses: Paket disisipi byte sampah berhasil diresinkronisasi dan Frame 0 byte-exact (1.059 B, val=92, chk=1, len=1, run=0, res=4)!";

        -- Tunggu penyelesaian uji real-time pendek (921.600 baud)
        if not real_test_done then
            wait until real_test_done for 50 ms;
        end if;
        assert real_test_done
            report "Timeout menunggu penyelesaian uji real-time 921.600 baud!" severity failure;
        assert real_mismatch = 0
            report "Ada ketidakcocokan byte ASCII pada Uji 5 terhadap Frame 0 ascii.hex pada 921.600 baud!" severity failure;
        -- Verifikasi tidak ada byte ASCII ekstra setelah 1.059 byte pada 921.600 baud (tunggu >= 2 periode frame = 25 ms)
        wait for 25 ms;
        assert real_byte_cnt = 1059
            report "Ada byte ASCII ekstra setelah 1.059 byte pada Uji 5 (terhitung: " & integer'image(real_byte_cnt) & ")!" severity failure;
        real_stop <= true;
        report "Uji 5 Sukses: 1 frame (1.059 byte) ASCII cocok 100% byte-exact pada 921.600 baud asli (tanpa byte ekstra).";
        report "TEST PASSED: tb_top_stream berhasil memverifikasi seluruh fungsionalitas streaming end-to-end (90 frame byte-exact, vektor galat, dan waktu nyata 921.600 baud)!";
        wait for 100 ns;
        stop;
    end process;

    -- Monitor penerimaan keluaran UART ASCII dari RsTx_real (1 Frame = 1.059 B pada 921.600 baud)
    rx_monitor_real : process
        constant BIT_TIME_921K : time := 1000000000 ns / 921600;
        file gold_file : text;
        variable gold_line : line;
        variable gold_byte : std_logic_vector(7 downto 0);
        variable rx_real_cnt   : integer := 0;
        variable rx_real_byte  : std_logic_vector(7 downto 0);
        variable mism          : integer := 0;
    begin
        file_open(gold_file, "data/golden/ascii.hex", read_mode);
        while not real_stop loop
            wait until falling_edge(RsTx_real) or real_stop;
            if real_stop then
                exit;
            end if;
            wait for BIT_TIME_921K / 2;
            if RsTx_real = '0' then
                wait for BIT_TIME_921K;
                for bit_i in 0 to 7 loop
                    rx_real_byte(bit_i) := RsTx_real;
                    wait for BIT_TIME_921K;
                end loop;
                if RsTx_real = '1' then
                    rx_real_cnt := rx_real_cnt + 1;
                    real_byte_cnt  <= rx_real_cnt;
                    if rx_real_cnt <= 1059 and not endfile(gold_file) then
                        readline(gold_file, gold_line);
                        hread(gold_line, gold_byte);
                        if rx_real_byte /= gold_byte then
                            mism := mism + 1;
                        end if;
                    end if;
                    if rx_real_cnt = 1059 then
                        real_test_done <= true;
                    end if;
                end if;
            end if;
        end loop;
        file_close(gold_file);

        real_mismatch  <= mism;
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
