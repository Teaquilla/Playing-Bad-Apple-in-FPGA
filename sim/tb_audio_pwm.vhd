--------------------------------------------------------------------------------
-- sim/tb_audio_pwm.vhd
-- Testbench Mandiri Modul Daun Modulator PWM Audio (Milestone 4 - Varian B)
--
-- Pengujian yang Dilakukan:
-- (1) Verifikasi tick sample_req tepat setiap 12.500 siklus selama >= 20 tick.
-- (2) Verifikasi duty cycle untuk sample 0x00, 0x80, 0xFF sesuai persamaan Varian B.
-- (3) Verifikasi ramp sample 0..255 pada laju 8 kHz: rata-rata duty per periode sampel.
-- (4) Verifikasi kontrol enable = '0' menghasilkan duty 50% (midpoint).
-- (5) Verifikasi lebar periode carrier konstan tepat 250 siklus clock (400 kHz).
--------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_audio_pwm is
end entity tb_audio_pwm;

architecture sim of tb_audio_pwm is

    -- Parameter generic
    constant CLK_FREQ_HZ : positive := 100_000_000;
    constant SAMPLE_RATE : positive := 8_000;
    constant CLK_PERIOD  : time     := 10 ns; -- 100 MHz clock

    constant CARRIER_CYCLES : positive := CLK_FREQ_HZ / (SAMPLE_RATE * 50); -- 250
    constant SAMPLE_CYCLES  : positive := CLK_FREQ_HZ / SAMPLE_RATE;        -- 12.500

    -- Sinyal interkoneksi DUT
    signal clk        : std_logic := '0';
    signal rst        : std_logic := '1';
    signal enable     : std_logic := '1';
    signal sample_in  : std_logic_vector(7 downto 0) := x"80";
    signal sample_req : std_logic;
    signal pwm_out    : std_logic;

    -- Sinyal sinkronisasi monitor testbench
    signal sim_done : boolean := false;
    signal tick_count_verified : natural := 0;

begin

    -- Pembangkit clock 100 MHz
    clk_gen : process
    begin
        while not sim_done loop
            clk <= '0';
            wait for CLK_PERIOD / 2;
            clk <= '1';
            wait for CLK_PERIOD / 2;
        end loop;
        wait;
    end process clk_gen;

    -- Instansiasi Unit Under Test (DUT)
    dut : entity work.audio_pwm
        generic map (
            CLK_FREQ_HZ => CLK_FREQ_HZ,
            SAMPLE_RATE => SAMPLE_RATE
        )
        port map (
            clk        => clk,
            rst        => rst,
            enable     => enable,
            sample_in  => sample_in,
            sample_req => sample_req,
            pwm_out    => pwm_out
        );

    -- Monitor Test 1: Verifikasi ketepatan interval tick sample_req (12.500 siklus)
    tick_monitor : process(clk)
        variable cycle_counter : natural := 0;
        variable first_tick    : boolean := true;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                cycle_counter := 0;
                first_tick    := true;
            else
                cycle_counter := cycle_counter + 1;
                if sample_req = '1' then
                    if not first_tick then
                        assert cycle_counter = SAMPLE_CYCLES
                            report "GAGAL [Test 1]: Interval antar-tick sample_req (" &
                                   integer'image(cycle_counter) & " siklus) != " &
                                   integer'image(SAMPLE_CYCLES) & " siklus!"
                            severity failure;
                        tick_count_verified <= tick_count_verified + 1;
                    else
                        first_tick := false;
                    end if;
                    cycle_counter := 0;
                end if;
            end if;
        end if;
    end process tick_monitor;

    -- Proses pengujian utama berurutan
    main_test : process
        variable high_cycles   : natural;
        variable expected_high : natural;
        variable prev_edge     : time := 0 ns;
        variable cur_edge      : time := 0 ns;
        variable period_time   : time;
    begin
        report "Memulai pengujian modul audio_pwm (Varian B)...";

        -- Reset perangkat
        rst <= '1';
        enable <= '1';
        sample_in <= x"80";
        wait for 5 * CLK_PERIOD;
        wait until rising_edge(clk);
        rst <= '0';

        ------------------------------------------------------------------------
        -- TEST 1: Verifikasi interval tick sample_req selama >= 20 tick
        ------------------------------------------------------------------------
        report "Menjalankan Test 1: Verifikasi >= 20 tick sample_req tepat tiap 12.500 siklus...";
        while tick_count_verified < 22 loop
            wait until rising_edge(clk);
        end loop;
        report "Test 1 LULUS: " & integer'image(tick_count_verified) &
               " tick terverifikasi tepat berjarak " & integer'image(SAMPLE_CYCLES) & " siklus clock.";

        ------------------------------------------------------------------------
        -- TEST 2: Verifikasi duty cycle untuk sample 0x00, 0x80, 0xFF
        ------------------------------------------------------------------------
        report "Menjalankan Test 2: Verifikasi duty cycle 0x00, 0x80, 0xFF...";

        -- Uji sample 0x00 (Ambang = 0 -> 0 siklus HIGH dari 250)
        wait until sample_req = '1';
        wait until rising_edge(clk);
        sample_in <= x"00";
        wait until sample_req = '1'; -- Tunggu latch sampel
        wait until rising_edge(clk); -- sample_cnt = 0, sample_reg aktif

        -- Ukur 1 periode carrier penuh (250 siklus)
        high_cycles := 0;
        for i in 0 to CARRIER_CYCLES - 1 loop
            wait until rising_edge(clk);
            if pwm_out = '1' then
                high_cycles := high_cycles + 1;
            end if;
        end loop;
        assert high_cycles = 0
            report "GAGAL [Test 2]: Sample 0x00 menghasilkan " & integer'image(high_cycles) &
                   " siklus HIGH (diharapkan 0)!"
            severity failure;

        -- Uji sample 0x80 (Ambang = 125 -> 125 siklus HIGH dari 250)
        sample_in <= x"80";
        wait until sample_req = '1';
        wait until rising_edge(clk);

        high_cycles := 0;
        for i in 0 to CARRIER_CYCLES - 1 loop
            wait until rising_edge(clk);
            if pwm_out = '1' then
                high_cycles := high_cycles + 1;
            end if;
        end loop;
        assert high_cycles = 125
            report "GAGAL [Test 2]: Sample 0x80 menghasilkan " & integer'image(high_cycles) &
                   " siklus HIGH (diharapkan 125)!"
            severity failure;

        -- Uji sample 0xFF (Ambang = 249 -> 249 siklus HIGH dari 250)
        sample_in <= x"FF";
        wait until sample_req = '1';
        wait until rising_edge(clk);

        high_cycles := 0;
        for i in 0 to CARRIER_CYCLES - 1 loop
            wait until rising_edge(clk);
            if pwm_out = '1' then
                high_cycles := high_cycles + 1;
            end if;
        end loop;
        assert high_cycles = 249
            report "GAGAL [Test 2]: Sample 0xFF menghasilkan " & integer'image(high_cycles) &
                   " siklus HIGH (diharapkan 249)!"
            severity failure;

        report "Test 2 LULUS: Duty cycle sample 0x00 (0/250), 0x80 (125/250), 0xFF (249/250) tepat.";

        ------------------------------------------------------------------------
        -- TEST 4: Verifikasi kontrol enable = '0' -> duty 50% (midpoint)
        ------------------------------------------------------------------------
        report "Menjalankan Test 4: Verifikasi enable = '0' menghasilkan duty 50%...";

        enable <= '0';
        sample_in <= x"FF"; -- Meskipun sample 0xFF, duty wajib 50%
        wait for 2 * CARRIER_CYCLES * CLK_PERIOD;
        wait until rising_edge(clk);

        high_cycles := 0;
        for i in 0 to CARRIER_CYCLES - 1 loop
            wait until rising_edge(clk);
            if pwm_out = '1' then
                high_cycles := high_cycles + 1;
            end if;
        end loop;
        assert high_cycles = 125
            report "GAGAL [Test 4]: enable='0' dengan sample 0xFF menghasilkan " &
                   integer'image(high_cycles) & " siklus HIGH (diharapkan 125)!"
            severity failure;

        sample_in <= x"00"; -- Uji dengan sample 0x00 saat disable
        wait for 2 * CARRIER_CYCLES * CLK_PERIOD;
        wait until rising_edge(clk);

        high_cycles := 0;
        for i in 0 to CARRIER_CYCLES - 1 loop
            wait until rising_edge(clk);
            if pwm_out = '1' then
                high_cycles := high_cycles + 1;
            end if;
        end loop;
        assert high_cycles = 125
            report "GAGAL [Test 4]: enable='0' dengan sample 0x00 menghasilkan " &
                   integer'image(high_cycles) & " siklus HIGH (diharapkan 125)!"
            severity failure;

        enable <= '1'; -- Kembalikan enable
        report "Test 4 LULUS: enable = '0' menghasilkan tepat duty 50% (125/250 siklus).";

        ------------------------------------------------------------------------
        -- TEST 5: Verifikasi lebar periode carrier konstan (250 siklus clock)
        ------------------------------------------------------------------------
        report "Menjalankan Test 5: Verifikasi periode carrier konstan 250 siklus (400 kHz)...";

        sample_in <= x"80";
        wait until sample_req = '1';
        wait until rising_edge(clk);

        -- Amati 10 pulsa tepi naik pwm_out berturutan
        wait until rising_edge(pwm_out);
        prev_edge := now;
        for k in 1 to 10 loop
            wait until rising_edge(pwm_out);
            cur_edge := now;
            period_time := cur_edge - prev_edge;
            assert period_time = CARRIER_CYCLES * CLK_PERIOD
                report "GAGAL [Test 5]: Periode carrier terukur " & time'image(period_time) &
                       " != " & time'image(CARRIER_CYCLES * CLK_PERIOD)
                severity failure;
            prev_edge := cur_edge;
        end loop;
        report "Test 5 LULUS: Lebar periode carrier konstan tepat 250 siklus (2,50 us = 400 kHz).";

        ------------------------------------------------------------------------
        -- TEST 3: Verifikasi ramp sample 0..255 pada 8 kHz
        ------------------------------------------------------------------------
        report "Menjalankan Test 3: Verifikasi ramp sample 0..255 pada laju 8 kHz...";

        for val in 0 to 255 loop
            -- Tunggu stroba sample_req
            wait until sample_req = '1';
            wait until rising_edge(clk);
            sample_in <= std_logic_vector(to_unsigned(val, 8));

            -- Tunggu tick berikutnya saat sample_in ini mulai aktif diputar
            wait until sample_req = '1';
            wait until rising_edge(clk); -- Sekarang sample_in aktif di sample_reg

            -- Akumulasi jumlah siklus HIGH selama 1 periode 8 kHz penuh (12.500 siklus)
            high_cycles := 0;
            for s in 0 to SAMPLE_CYCLES - 1 loop
                wait until rising_edge(clk);
                if pwm_out = '1' then
                    high_cycles := high_cycles + 1;
                end if;
            end loop;

            -- Evaluasi nilai teoritis Varian B: 50 periode * ((val * 250) / 256)
            expected_high := 50 * ((val * CARRIER_CYCLES) / 256);
            assert high_cycles = expected_high
                report "GAGAL [Test 3]: Sample ramp " & integer'image(val) &
                       " menghasilkan total HIGH " & integer'image(high_cycles) &
                       " (diharapkan " & integer'image(expected_high) & ")!"
                severity failure;
        end loop;
        report "Test 3 LULUS: Seluruh 256 nilai ramp (0..255) menghasilkan rata-rata duty per periode 8 kHz tepat.";

        ------------------------------------------------------------------------
        -- RINGKASAN AKHIR
        ------------------------------------------------------------------------
        report "================================================================";
        report "TEST PASSED: tb_audio_pwm (Varian B) - SELURUH PENGUJIAN LOLOS!";
        report "================================================================";

        sim_done <= true;
        wait;
    end process main_test;

end architecture sim;

