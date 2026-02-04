function OUT = sbm_eta_cond_v27_figplus()
% η(伝達効率)をスイープし、各ηで (m[g], ω[deg], k) を最適化する。
% 追加:
%  - 所持おもり限定
%  - k=48固定 + 所持おもり
%  - r_eff(x)のグラフ
%  - 論文用_重要結果.xlsx
%  - 損失η→必要おもり、必要トルク(N·m)のグラフ
%  - ★ばね理論（Votta / 土屋-吉村）単体のリップル率を表とグラフで出力
%     Ripple = (max(F)-min(F))/abs(mean(F))
%     出力:
%       出力_CSV\ばね理論_リップル率.csv
%       出力_PNG\ばね理論_リップル率.png
%       出力_表\最適解_まとめ.xlsx の sheet: spring_ripple
%
% ★今回追加（重要）:
%  - 「減少なし（厳密）」= すべての x で ΔF(x) >= 0 を満たす解も計算
%  - リップル率の比較を指定7条件で作成して別ファイルに保存
%     比較対象:
%       1) ばねのみ（Votta / 土屋-吉村）
%       2) 理想（効率無視，k=1..200 を自由に選択）・最適
%       3) JIS再現（kをJIS生成リストに限定）・最適
%       4) 理想（効率無視）・非減少（厳密）
%       5) JIS再現・非減少（厳密）
%       6) k=48（所持おもり）・最適
%       7) k=48（所持おもり）・非減少（厳密）
%     出力:
%       出力_論文用\リップル率_比較.xlsx
%       出力_PNG\リップル率_比較.png
%       出力_CSV\リップル率_比較.csv
% =========================================================================

clear; clc; close all;
thisDir = fileparts(mfilename('fullpath'));

%% ===== 0) kリストを読み込み（無ければ生成）=====
matK = fullfile(thisDir, 'k_list_3shaft_JIS_m1.mat');
if ~exist(matK,'file')
    fprintf('k list MAT not found. Generating...\n');
    make_k_list_3shaft_JIS_m1(); % このファイル内に実装あり
end
S = load(matK, 'k_list', 'gear_table');

% 旧版MATの互換チェック．歯車比の定義が逆だと k_value が一致しない
needRebuild = false;
if isfield(S,'gear_table') && ~isempty(S.gear_table)
    GT = S.gear_table;
    if all(ismember({'z1_drive','z2_driven','z3_drive','z4_driven','k_value'}, GT.Properties.VariableNames))
        k_check = (GT.z2_driven ./ GT.z1_drive) .* (GT.z4_driven ./ GT.z3_drive);
        if max(abs(k_check - GT.k_value)) > 1e-12
            needRebuild = true;
        end
    end
end
if needRebuild
    fprintf('k list MAT exists but gear ratio definition is old. Rebuilding...\n');
    make_k_list_3shaft_JIS_m1();
    S = load(matK, 'k_list', 'gear_table');
end

k_list_all = S.k_list(:)';

% k範囲フィルタ
K_USE_MIN = 1;
K_USE_MAX = 200;
k_list = k_list_all(k_list_all>=K_USE_MIN & k_list_all<=K_USE_MAX);
k_list = unique(k_list);

fprintf('Loaded k count = %d (filtered range [%g,%g])\n', numel(k_list), K_USE_MIN, K_USE_MAX);

%% ===== 1) η スイープ条件 =====
eta_start = 0.60;
eta_end   = 1.00;
eta_step  = 0.05;  % 0.05刻み
eta_list  = eta_start:eta_step:eta_end;

%% ===== 2) 探索離散条件 =====
m_g_list_all = 10:10:1000;   % 10g刻み，最大1000g
omega_deg_list = 0:5:360;     % 5deg刻み（360は0と同値のため後で除外）
if omega_deg_list(end) == 360
    omega_deg_list(end) = []; % 360degは0degと同値なので重複を避ける
end
omega_rad_list = deg2rad(omega_deg_list);
% 所持おもり
m_g_list_owned = [10 20 50 100 200 500];

% 歯車比固定
k_fixed_48 = 48; % 歯数比固定（減速比 48）
L_max_mm = 900;
x_eval_min_mm = 0;
x_eval_max_mm = 900;
dL_mm = 2;

% metric = (max-min)/abs(mean)（リップル率）
useRipplePct = true;

% 合成符号（+1: ばね力に加算）
DeltaF_sign = +1;

%% ===== 4) 「増やす」制約（ゆるめ）=====
positiveFractionThresh = 0.95;
useAlwaysPositive = true;  % trueだとmin(ΔF)>=0 を要求（厳密）

%% ===== 5) ばね理論パラメータ =====
spring.E_Nmm2    = 193000;
spring.nu        = 0.30;
spring.b_mm      = 20.0;
spring.t_mm      = 0.14;

spring.R0_mm     = 10.25;
spring.r_core_mm = 10.8;
spring.ell_mm    = 1000;

spring.I_mm4 = spring.b_mm * spring.t_mm^3 / 12;
spring.coef  = (spring.E_Nmm2 * spring.I_mm4) / (2*(1 - spring.nu^2));

authorLabelEN = 'Tsuchiya-Yoshimura';
authorLabelJP = '土屋-吉村';

%% ===== 6) 機構パラメータ =====
mech.g_mps2       = 9.80665;
mech.L_arm_mm     = 50.0;

mech.r_mode       = 'LAYER'; % 'DRUM' or 'LAYER'
mech.drum_diam_mm = 22;      % 巻胴直径
mech.t_rope_mm    = 0.14;    % 紐厚

%% ===== 7) 出力設定 =====
savePNG = true;
saveCSV = true;
saveXLSX = true;
saveSummaryTablePNG = true;

dpi = 300;
showFigures = false; % falseなら非表示で保存して閉じる

outPngDir = fullfile(thisDir, '出力_PNG');
outCsvDir = fullfile(thisDir, '出力_CSV');
outTblDir = fullfile(thisDir, '出力_表');
outPaperDir = fullfile(thisDir, '出力_論文用');
outPngDirK48 = fullfile(outPngDir, 'k48_fixed');

if savePNG && ~exist(outPngDirK48,'dir'); mkdir(outPngDirK48); end
if savePNG && ~exist(outPngDir,'dir'); mkdir(outPngDir); end
if saveCSV && ~exist(outCsvDir,'dir'); mkdir(outCsvDir); end
if saveXLSX && ~exist(outTblDir,'dir'); mkdir(outTblDir); end
if ~exist(outPaperDir,'dir'); mkdir(outPaperDir); end

% --- 論文用の図と表を別フォルダに保存 ---
paperFigDir = fullfile(thisDir, '論文図');
paperTblDir = fullfile(thisDir, '論文表');
if ~exist(paperFigDir,'dir'); mkdir(paperFigDir); end
if ~exist(paperTblDir,'dir'); mkdir(paperTblDir); end


%% ======================================================================
% 8) 前計算（x, r_eff, theta_shaft, spring forces）
%% ======================================================================
x_all = (0:dL_mm:L_max_mm)';
idxEval = (x_all>=x_eval_min_mm) & (x_all<=x_eval_max_mm);
x_mm = x_all(idxEval);
N = numel(x_mm);

% r_eff(x)
r0_mm = mech.drum_diam_mm/2;
switch mech.r_mode
    case 'DRUM'
        r_eff_mm = r0_mm*ones(N,1);
    case 'LAYER'
        r_eff_mm = r0_mm + (x_mm./(2*pi*r0_mm)).*mech.t_rope_mm;
    otherwise
        error('mech.r_mode must be DRUM or LAYER');
end

% theta_shaft(x): dtheta = dL / r_eff
theta_shaft = zeros(N,1);
for i=2:N
    theta_shaft(i) = theta_shaft(i-1) + dL_mm / r_eff_mm(i-1);
end

% spring forces on grid
[~, F_Votta, F_TY] = springForcesOnGrid(x_mm, spring);

% 1gのアームトルク振幅（Nmm/g）
m1_kg = 0.001;
tau_arm_amp_1g = (m1_kg * mech.g_mps2 * (mech.L_arm_mm/1000)) * 1000; % Nmm/g
mech.tau_arm_amp_1g = tau_arm_amp_1g; % Nmm per gram (振幅)

%% ===== ★ばね理論（単体）のリップル率を計算して保存 =====
[rV, pkpkV, meanV]     = calcRipple1D(F_Votta);
[rTY, pkpkTY, meanTY] = calcRipple1D(F_TY);

TspringRipple = table( ...
    {'Votta'; authorLabelEN}, ...
    [meanV; meanTY], ...
    [pkpkV; pkpkTY], ...
    [rV; rTY], ...
    [100*rV; 100*rTY], ...
    'VariableNames', {'Model','Mean_N','PeakToPeak_N','RippleRatio','RipplePct'});

if saveCSV
    writetable(TspringRipple, fullfile(outCsvDir, 'ばね理論_リップル率.csv'));
end

if savePNG
    fig = newFig(showFigures);
set(fig, 'Units','pixels', 'Position', [100 100 1600 950]);
    bar(categorical(TspringRipple.Model), TspringRipple.RipplePct);
    grid on;
    ylabel('リップル率 [%] = 100*(max-min)/|mean|');
    title('ばね理論（単体）のリップル率');

    addBarValueLabels(gca);

    saveFigPNG(fig, outPngDir, 'ばね理論_リップル率.png');
end


%% ===== ばね理論のみ図（リップル率を図中に記入）=====
if savePNG
    fig = newFig(showFigures); hold on;
    plot(x_mm, F_Votta, 'LineWidth', 1.6);
    plot(x_mm, F_TY,    'LineWidth', 1.6);
    grid on;
    xlabel('ストローク x [mm]');
    ylabel('ばね力 [N]');
    title('ばね理論のみ');
    legend({'Votta', authorLabelJP}, 'Location', 'best');

    % リップル率を図中に記入
    addRippleBox(fig, ...
        {'Votta ばね力', [authorLabelJP ' ばね力']}, ...
        {F_Votta, F_TY}, ...
        [0.02 0.72 0.55 0.24]);

    saveFigPNG(fig, outPngDir, 'ばね理論のみ.png');
end

%% ===== 巻胴有効半径 r_eff(x)（リップル率を図中に記入）=====
if savePNG
    fig = newFig(showFigures); hold on;
    plot(x_mm, r_eff_mm, 'LineWidth', 1.8);
    grid on;
    xlabel('ストローク x [mm]');
    ylabel('巻胴の有効半径 r_{eff} [mm]');
    title('巻胴有効半径 r_{eff}(x) の変化');

    addRippleBox(fig, ...
        {'r_{eff}(x)'}, ...
        {r_eff_mm}, ...
        [0.02 0.78 0.45 0.16]);

    saveFigPNG(fig, outPngDir, '巻胴有効半径の変化.png');
end


%% ======================================================================
% 9) 3種類の解析を実行（all / owned / k48+owned）
%% ======================================================================
fprintf('\n===== RUN 1/3: 全探索（m=50:50:1000, k=JISリスト） =====\n');
[Tsum_all, Tlong_all] = runSweep( ...
    eta_list, k_list, m_g_list_all, omega_deg_list, omega_rad_list, ...
    x_mm, r_eff_mm, theta_shaft, F_Votta, F_TY, ...
    DeltaF_sign, tau_arm_amp_1g, useRipplePct, ...
    positiveFractionThresh, useAlwaysPositive, authorLabelEN);

fprintf('\n===== RUN 2/3: 所持おもり限定（20/50/100/200/500g, k=JISリスト） =====\n');
[Tsum_owned, Tlong_owned, TperMass_JIS_owned] = runSweep( ...
    eta_list, k_list, m_g_list_owned, omega_deg_list, omega_rad_list, ...
    x_mm, r_eff_mm, theta_shaft, F_Votta, F_TY, ...
    DeltaF_sign, tau_arm_amp_1g, useRipplePct, ...
    positiveFractionThresh, useAlwaysPositive, authorLabelEN);

fprintf('\n===== RUN 3/3: k=48固定 + 所持おもり（20/50/100/200/500g） =====\n');
[Tsum_k48_owned, Tlong_k48_owned, TperMass_k48_owned] = runSweep( ...
    eta_list, k_fixed_48, m_g_list_owned, omega_deg_list, omega_rad_list, ...
    x_mm, r_eff_mm, theta_shaft, F_Votta, F_TY, ...
    DeltaF_sign, tau_arm_amp_1g, useRipplePct, ...
    positiveFractionThresh, useAlwaysPositive, authorLabelEN);

% 全探索の「全ηの中で一番良い点」を抜き出し
Tbest_overall = calcBestOverall(Tsum_all, authorLabelEN);

%% ======================================================================
% 10) 保存（XLSX/CSV/PNG表）
%% ======================================================================
xlsxPath = fullfile(outTblDir, '最適解_まとめ.xlsx');
if saveXLSX
    if exist(xlsxPath,'file'); delete(xlsxPath); end

    writetable(Tsum_all,       xlsxPath, 'Sheet', 'summary_all');
    writetable(Tlong_all,      xlsxPath, 'Sheet', 'long_all');
    writetable(Tbest_overall,  xlsxPath, 'Sheet', 'best_overall');

    writetable(Tsum_owned,     xlsxPath, 'Sheet', 'summary_owned');
    writetable(Tlong_owned,    xlsxPath, 'Sheet', 'long_owned');

    writetable(Tsum_k48_owned,  xlsxPath, 'Sheet', 'summary_k48_owned');
    writetable(Tlong_k48_owned, xlsxPath, 'Sheet', 'long_k48_owned');

%% --- 追加RUN（要求図用） ---
    % --- 追加RUN（標準状態／理想状態／JIS規格／歯数48の要求出力用） ---
    fprintf('\n=== RUN 4/6: k=48固定 + 全おもり (m=10..500) ===\n');
    k_list_48 = k_fixed_48;
    [Tsum_k48_all, Tlong_k48_all] = runSweep(eta_list, k_list_48, m_g_list_all, omega_deg_list, omega_rad_list, ...
        x_mm, r_eff_mm, theta_shaft, F_Votta, F_TY, DeltaF_sign, tau_arm_amp_1g, useRipplePct, positiveFractionThresh, useAlwaysPositive, ...
        'k48_all');
    writetable(Tsum_k48_all, xlsxPath, 'Sheet', 'summary_k48_all');
    writetable(Tlong_k48_all, xlsxPath, 'Sheet', 'long_k48_all');

    fprintf('\n=== RUN 5/6: 理想状態(k=1..200) + 全おもり (m=10..500) ===\n');
    k_list_ideal = (K_USE_MIN:1:K_USE_MAX);
    [Tsum_ideal_all, Tlong_ideal_all] = runSweep(eta_list, k_list_ideal, m_g_list_all, omega_deg_list, omega_rad_list, ...
        x_mm, r_eff_mm, theta_shaft, F_Votta, F_TY, DeltaF_sign, tau_arm_amp_1g, useRipplePct, positiveFractionThresh, useAlwaysPositive, ...
        'ideal_all');
    writetable(Tsum_ideal_all, xlsxPath, 'Sheet', 'summary_ideal_all');
    writetable(Tlong_ideal_all, xlsxPath, 'Sheet', 'long_ideal_all');

    fprintf('\n=== RUN 6/6: 理想状態(k=1..200) + 所持おもり + perMass ===\n');
    [Tsum_ideal_owned, Tlong_ideal_owned, TperMass_ideal_owned] = runSweep(eta_list, k_list_ideal, m_g_list_owned, omega_deg_list, omega_rad_list, ...
        x_mm, r_eff_mm, theta_shaft, F_Votta, F_TY, DeltaF_sign, tau_arm_amp_1g, useRipplePct, positiveFractionThresh, useAlwaysPositive, ...
        'ideal_owned');
    writetable(Tsum_ideal_owned, xlsxPath, 'Sheet', 'summary_ideal_owned');
    writetable(Tlong_ideal_owned, xlsxPath, 'Sheet', 'long_ideal_owned');
    writetable(TperMass_ideal_owned, xlsxPath, 'Sheet', 'perMass_ideal_owned');

    writetable(TperMass_JIS_owned, xlsxPath, 'Sheet', 'perMass_JIS_owned');
    writetable(TperMass_k48_owned, xlsxPath, 'Sheet', 'perMass_k48_owned');


    % ★追加：ばね理論リップル率
    writetable(TspringRipple,  xlsxPath, 'Sheet', 'spring_ripple');

    writetable(renameSummaryToJP(Tsum_all),       xlsxPath, 'Sheet', 'summary_all_JP');
    writetable(renameSummaryToJP(Tsum_owned),     xlsxPath, 'Sheet', 'summary_owned_JP');
    writetable(renameSummaryToJP(Tsum_k48_owned), xlsxPath, 'Sheet', 'summary_k48_owned_JP');

    fprintf('\nXLSX saved to: %s\n', xlsxPath);
end

if saveCSV
    writetable(Tlong_all,      fullfile(outCsvDir, '最適解_long_all.csv'));
    writetable(Tlong_owned,    fullfile(outCsvDir, '最適解_long_owned.csv'));
    writetable(Tlong_k48_owned,fullfile(outCsvDir, '最適解_long_k48_owned.csv'));
    fprintf('\nCSV saved to: %s\n', outCsvDir);
end

if saveSummaryTablePNG && savePNG
    saveTableAsPNG(Tsum_all,      fullfile(outPngDir, '最適解_サマリー表_all.png'),            [1400, 420], 11);
    saveTableAsPNG(Tsum_owned,    fullfile(outPngDir, '最適解_サマリー表_所持おもり.png'),     [1400, 420], 11);
    saveTableAsPNG(Tsum_k48_owned,fullfile(outPngDir, '最適解_サマリー表_k48_所持おもり.png'), [1400, 420], 11);
end

% ============================================================
% ★更新: RUN3（k=48固定）の図を「最適」「増やす」の2枚/ηにまとめて保存
%        さらに m と ω の η依存グラフも作成
%        それぞれの図にリップル率を記入
% ============================================================
if savePNG
    % 0) すべてのk=48図で縦軸を統一するための範囲を前計算
    yLimK48 = computeGlobalYLimK48(Tsum_k48_owned, x_mm, r_eff_mm, theta_shaft, spring, DeltaF_sign, tau_arm_amp_1g);

    % 1) ηごとまとめ図（2枚/η）
    for i = 1:height(Tsum_k48_owned)
        eta = Tsum_k48_owned.eta(i);

        % ---- 最適（条件なし）----
        bestV_U  = struct('metric',Tsum_k48_owned.V_U_metric(i),'m_g',Tsum_k48_owned.V_U_m_g(i), ...
                          'omega_deg',Tsum_k48_owned.V_U_omega_deg(i),'k',Tsum_k48_owned.V_U_k(i));
        bestTY_U = struct('metric',Tsum_k48_owned.TY_U_metric(i),'m_g',Tsum_k48_owned.TY_U_m_g(i), ...
                          'omega_deg',Tsum_k48_owned.TY_U_omega_deg(i),'k',Tsum_k48_owned.TY_U_k(i));

        saveBestPlotPairK48(bestV_U, bestTY_U, '最適', eta, outPngDirK48, dpi, showFigures, ...
            x_mm, r_eff_mm, theta_shaft, spring, DeltaF_sign, tau_arm_amp_1g, authorLabelJP, yLimK48);

        % ---- 増やす（制約あり）----
        bestV_I  = struct('metric',Tsum_k48_owned.V_I_metric(i),'m_g',Tsum_k48_owned.V_I_m_g(i), ...
                          'omega_deg',Tsum_k48_owned.V_I_omega_deg(i),'k',Tsum_k48_owned.V_I_k(i));
        bestTY_I = struct('metric',Tsum_k48_owned.TY_I_metric(i),'m_g',Tsum_k48_owned.TY_I_m_g(i), ...
                          'omega_deg',Tsum_k48_owned.TY_I_omega_deg(i),'k',Tsum_k48_owned.TY_I_k(i));

        saveBestPlotPairK48(bestV_I, bestTY_I, '増やす', eta, outPngDirK48, dpi, showFigures, ...
            x_mm, r_eff_mm, theta_shaft, spring, DeltaF_sign, tau_arm_amp_1g, authorLabelJP, yLimK48);
    end

    % 2) m と ω の η依存グラフ（最適，増やす）
    plotK48ParamsVsEta(Tsum_k48_owned, outPngDirK48, dpi, showFigures, authorLabelJP);
end


%% ======================================================================
% 12) 論文用：別ファイルに保存（重要結果 + 補償グラフ + k=48厳密）
%% ======================================================================
makePaperOutputs( ...
    paperTblDir, paperFigDir, outPngDir, ...
    k_list, m_g_list_all, m_g_list_owned, omega_deg_list, omega_rad_list, ...
    x_mm, r_eff_mm, theta_shaft, F_Votta, F_TY, ...
    DeltaF_sign, tau_arm_amp_1g, useRipplePct, ...
    positiveFractionThresh, authorLabelEN, authorLabelJP, ...
    Tsum_all, Tsum_owned, Tsum_k48_owned, ...
    k_fixed_48);

%% ======================================================================
% 13) ★追加：リップル率の比較（指定7条件）を別ファイルにまとめる
%% ======================================================================
makeRippleCompareOutputs( ...
    paperTblDir, paperFigDir, outPngDir, outCsvDir, ...
    x_mm, r_eff_mm, theta_shaft, ...
    F_Votta, F_TY, ...
    DeltaF_sign, tau_arm_amp_1g, ...
    k_list, K_USE_MIN, K_USE_MAX, ...
    m_g_list_all, omega_deg_list, omega_rad_list, ...
    m_g_list_owned, k_fixed_48, ...
    Tsum_all, Tsum_k48_owned, ...
    authorLabelEN, authorLabelJP, ...
    dpi, showFigures, savePNG, saveCSV);

%% --- 要求されたフォルダ構成の出力（標準状態，理想状態，JIS規格，歯数48） ---
makeRequestedFileSets_COND(paperTblDir, paperFigDir, ...
    x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, ...
    eta_list, ...
    Tsum_ideal_all, Tsum_ideal_owned, TperMass_ideal_owned, ...
    Tsum_all, Tsum_owned, TperMass_JIS_owned, ...
    Tsum_k48_all, Tsum_k48_owned, TperMass_k48_owned, ...
    authorLabelEN, showFigures);


fprintf('\nPNG saved to: %s\n', outPngDir);
fprintf('Paper tables saved to: %s\n', paperTblDir);
fprintf('Paper figures saved to: %s\n', paperFigDir);


% ========================== 返り値 OUT ==========================
OUT = struct();
OUT.thisDir = thisDir;
OUT.paths = struct( ...
    'outTblDir', outTblDir, ...
    'outCsvDir', outCsvDir, ...
    'outPngDir', outPngDir, ...
    'paperTblDir', paperTblDir, ...
    'paperFigDir', paperFigDir);

if exist('Tsum_all','var'),         OUT.Tsum_all = Tsum_all; end
if exist('Tsum_owned','var'),       OUT.Tsum_owned = Tsum_owned; end
if exist('Tsum_k48_owned','var'),   OUT.Tsum_k48_owned = Tsum_k48_owned; end
if exist('Tsum_k48_all','var'),     OUT.Tsum_k48_all = Tsum_k48_all; end
if exist('Tsum_ideal_all','var'),   OUT.Tsum_ideal_all = Tsum_ideal_all; end
if exist('Tsum_ideal_owned','var'), OUT.Tsum_ideal_owned = Tsum_ideal_owned; end
if exist('Tripple','var'),          OUT.Tripple = Tripple; end


end


%% ============================ Sweep runner ============================
function [Tsum, Tlong, TperMass] = runSweep( ...
    eta_list, k_list, m_g_list, omega_deg_list, omega_rad_list, ...
    x_mm, r_eff_mm, theta_shaft, F_Votta, F_TY, ...
    DeltaF_sign, tau_arm_amp_1g, useRipplePct, ...
    positiveFractionThresh, useAlwaysPositive, authorLabelEN)

resLong = [];
resSummary = [];

wantPerMass = (nargout >= 3);
if wantPerMass && numel(m_g_list) > 12
    warning('TperMass requested but m_g_list is large (%d). TperMass will be skipped.', numel(m_g_list));
    wantPerMass = false;
end
resPerMass = [];

for eta = eta_list
    fprintf('\n============================================================\n');
    fprintf('ETA = %.2f\n', eta);
    fprintf('============================================================\n');

    bestV      = initBest();
    bestTY     = initBest();
    bestV_inc  = initBest();
    bestTY_inc = initBest();

    if wantPerMass
        M = numel(m_g_list);

        perV_metric      = inf(1,M); perV_omega_deg      = nan(1,M); perV_k      = nan(1,M);
        perTY_metric     = inf(1,M); perTY_omega_deg     = nan(1,M); perTY_k     = nan(1,M);

        perV_inc_metric  = inf(1,M); perV_inc_omega_deg  = nan(1,M); perV_inc_k  = nan(1,M);
        perTY_inc_metric = inf(1,M); perTY_inc_omega_deg = nan(1,M); perTY_inc_k = nan(1,M);
    end

    mVec = reshape(m_g_list, 1, 1, []); % 1x1xM

    for k = k_list
        theta_arm = theta_shaft ./ k; % Nx1
        Ssin = sin(theta_arm + reshape(omega_rad_list, 1, [])); % NxO

        tau_arm_1g   = tau_arm_amp_1g .* Ssin;      % NxO (Nmm/g)
        tau_shaft_1g = (eta .* tau_arm_1g) ./ k;    % NxO (Nmm/g)
        DeltaF_1g    = tau_shaft_1g ./ r_eff_mm;    % NxO (N/g)

        dF3  = bsxfun(@times, DeltaF_1g, mVec);                % NxOxM
        F3V  = bsxfun(@plus, F_Votta, DeltaF_sign .* dF3);     % NxOxM
        F3TY = bsxfun(@plus, F_TY,    DeltaF_sign .* dF3);     % NxOxM

        metV  = calcMetric3D(F3V,  useRipplePct); % OxM
        metTY = calcMetric3D(F3TY, useRipplePct); % OxM

        bestV  = updateBestFromMetric(bestV,  metV,  m_g_list, omega_deg_list, k);
        bestTY = updateBestFromMetric(bestTY, metTY, m_g_list, omega_deg_list, k);

        % ---- 増やす制約判定 ----
        dF_sign_1g = DeltaF_sign .* DeltaF_1g; % NxO
        posFrac = mean(dF_sign_1g >= 0, 1);    % 1xO
        meanDF  = mean(dF_sign_1g, 1);         % 1xO
        minDF   = min(dF_sign_1g, [], 1);      % 1xO

        if useAlwaysPositive
            okOmega = (minDF > 0);
        else
            okOmega = (meanDF > 0) & (posFrac >= positiveFractionThresh);
        end

        % perMass 条件なし
        if wantPerMass
            [minVtmp, idxOtmp] = min(metV, [], 1);
            improve = (minVtmp < perV_metric);
            perV_metric(improve) = minVtmp(improve);
            perV_omega_deg(improve) = omega_deg_list(idxOtmp(improve));
            perV_k(improve) = k;

            [minTYtmp, idxOtmp] = min(metTY, [], 1);
            improve = (minTYtmp < perTY_metric);
            perTY_metric(improve) = minTYtmp(improve);
            perTY_omega_deg(improve) = omega_deg_list(idxOtmp(improve));
            perTY_k(improve) = k;
        end

        if any(okOmega)
            metV_inc  = metV;   metV_inc(~okOmega, :)   = inf;
            metTY_inc = metTY;  metTY_inc(~okOmega, :)  = inf;

            bestV_inc  = updateBestFromMetric(bestV_inc,  metV_inc,  m_g_list, omega_deg_list, k);
            bestTY_inc = updateBestFromMetric(bestTY_inc, metTY_inc, m_g_list, omega_deg_list, k);

            % perMass 増やす
            if wantPerMass
                [minVtmp, idxOtmp] = min(metV_inc, [], 1);
                improve = (minVtmp < perV_inc_metric);
                perV_inc_metric(improve) = minVtmp(improve);
                perV_inc_omega_deg(improve) = omega_deg_list(idxOtmp(improve));
                perV_inc_k(improve) = k;

                [minTYtmp, idxOtmp] = min(metTY_inc, [], 1);
                improve = (minTYtmp < perTY_inc_metric);
                perTY_inc_metric(improve) = minTYtmp(improve);
                perTY_inc_omega_deg(improve) = omega_deg_list(idxOtmp(improve));
                perTY_inc_k(improve) = k;
            end
        end

    end

    fprintf('\nFINAL (eta=%.2f) - Unconstrained\n', eta);
    printOne('Votta', bestV);
    printOne(authorLabelEN, bestTY);

    fprintf('\nFINAL (eta=%.2f) - Increasing constrained\n', eta);
    if isfinite(bestV_inc.metric)
        printOne('Votta (increasing)', bestV_inc);
    else
        fprintf('Votta (increasing): No feasible solution.\n');
    end
    if isfinite(bestTY_inc.metric)
        printOne([authorLabelEN ' (increasing)'], bestTY_inc);
    else
        fprintf('%s (increasing): No feasible solution.\n', authorLabelEN);
    end

    % long（4行/η）
    resLong = [resLong; packLong(eta, 'Votta',      'Unconstrained', bestV)]; %#ok<AGROW>
    resLong = [resLong; packLong(eta, authorLabelEN,'Unconstrained', bestTY)]; %#ok<AGROW>
    resLong = [resLong; packLong(eta, 'Votta',      'Increasing',    bestV_inc)]; %#ok<AGROW>
    resLong = [resLong; packLong(eta, authorLabelEN,'Increasing',    bestTY_inc)]; %#ok<AGROW>

    % summary（1行/η）
    resSummary = [resSummary; packSummary(eta, bestV, bestTY, bestV_inc, bestTY_inc)]; %#ok<AGROW>

    % perMass（mごとに行を追加）
    if wantPerMass
        for j = 1:numel(m_g_list)
            resPerMass = [resPerMass; packPerMass(eta, m_g_list(j), ...
                perV_metric(j),      perV_omega_deg(j),      perV_k(j), ...
                perTY_metric(j),     perTY_omega_deg(j),     perTY_k(j), ...
                perV_inc_metric(j),  perV_inc_omega_deg(j),  perV_inc_k(j), ...
                perTY_inc_metric(j), perTY_inc_omega_deg(j), perTY_inc_k(j))]; %#ok<AGROW>
        end
    end

end

Tlong = struct2table(resLong);
Tsum  = struct2table(resSummary);

if nargout >= 3
    if wantPerMass
        TperMass = struct2table(resPerMass);
    else
        TperMass = table();
    end
end

end

%% ============================ Best overall ============================
function Tbest = calcBestOverall(Tsum, authorLabelEN)
cats = { ...
    'Votta (Unconstrained)','V_U_metric','V_U_m_g','V_U_omega_deg','V_U_k'; ...
    [authorLabelEN ' (Unconstrained)'],'TY_U_metric','TY_U_m_g','TY_U_omega_deg','TY_U_k'; ...
    'Votta (Increasing)','V_I_metric','V_I_m_g','V_I_omega_deg','V_I_k'; ...
    [authorLabelEN ' (Increasing)'],'TY_I_metric','TY_I_m_g','TY_I_omega_deg','TY_I_k'};

Category = {};
eta = []; m_g = []; omega_deg = []; k = []; metric = [];

for i=1:size(cats,1)
    catName = cats{i,1};
    metCol  = cats{i,2};
    mCol    = cats{i,3};
    oCol    = cats{i,4};
    kCol    = cats{i,5};

    [metMin, idx] = min(Tsum.(metCol));
    Category{end+1,1} = catName; %#ok<AGROW>
    eta(end+1,1) = Tsum.eta(idx); %#ok<AGROW>
    m_g(end+1,1) = Tsum.(mCol)(idx); %#ok<AGROW>
    omega_deg(end+1,1) = Tsum.(oCol)(idx); %#ok<AGROW>
    k(end+1,1) = Tsum.(kCol)(idx); %#ok<AGROW>
    metric(end+1,1) = metMin; %#ok<AGROW>
end

Tbest = table(Category, eta, m_g, omega_deg, k, metric);
end


%% ============================ JP rename for summary ====================
function Tjp = renameSummaryToJP(T)
Tjp = T;
Tjp.Properties.VariableNames = { ...
    'eta', ...
    'Votta_U_m_g','Votta_U_omega_deg','Votta_U_k','Votta_U_metric', ...
    'TY_U_m_g','TY_U_omega_deg','TY_U_k','TY_U_metric', ...
    'Votta_I_m_g','Votta_I_omega_deg','Votta_I_k','Votta_I_metric', ...
    'TY_I_m_g','TY_I_omega_deg','TY_I_k','TY_I_metric'};
end


%% ============================ Paper outputs ===========================
function makePaperOutputs( ...
    paperTblDir, paperFigDir, outPngDir, ...
    k_list, m_g_list_all, m_g_list_owned, omega_deg_list, omega_rad_list, ...
    x_mm, r_eff_mm, theta_shaft, F_Votta, F_TY, ...
    DeltaF_sign, tau_arm_amp_1g, useRipplePct, ...
    positiveFractionThresh, authorLabelEN, authorLabelJP, ...
    Tsum_all, Tsum_owned, Tsum_k48_owned, ...
    k_fixed_48)

eta0 = 1.00;

% (1) η=1, 条件なし（理想）
row = Tsum_all(Tsum_all.eta==eta0, :);
if isempty(row)
    error('Tsum_all に eta=1.00 の行がありません。');
end
pick1 = pickBetterOfTwo( ...
    row.V_U_metric, row.V_U_m_g, row.V_U_omega_deg, row.V_U_k, 'Votta', ...
    row.TY_U_metric,row.TY_U_m_g,row.TY_U_omega_deg,row.TY_U_k, authorLabelEN);

% (2) η=1, 「ばね力より減少しない」(厳密): min(ΔF)>=0（JIS k_list）
[p2V, p2TY] = solveStrictNoDecrease( ...
    eta0, k_list, m_g_list_all, omega_deg_list, omega_rad_list, ...
    x_mm, r_eff_mm, theta_shaft, F_Votta, F_TY, ...
    DeltaF_sign, tau_arm_amp_1g, useRipplePct);

pick2 = pickBetterOfTwo( ...
    p2V.metric, p2V.m_g, p2V.omega_deg, p2V.k, 'Votta', ...
    p2TY.metric,p2TY.m_g,p2TY.omega_deg,p2TY.k, authorLabelEN);

% (3) η=1, k=48固定 + 所持おもり（最適）
row48 = Tsum_k48_owned(Tsum_k48_owned.eta==eta0, :);
if isempty(row48)
    [Tsum_tmp, ~] = runSweep( ...
        eta0, k_fixed_48, m_g_list_owned, omega_deg_list, omega_rad_list, ...
        x_mm, r_eff_mm, theta_shaft, F_Votta, F_TY, ...
        DeltaF_sign, tau_arm_amp_1g, useRipplePct, ...
        positiveFractionThresh, false, authorLabelEN);
    row48 = Tsum_tmp;
end
pick3 = pickBetterOfTwo( ...
    row48.V_U_metric, row48.V_U_m_g, row48.V_U_omega_deg, row48.V_U_k, 'Votta', ...
    row48.TY_U_metric,row48.TY_U_m_g,row48.TY_U_omega_deg,row48.TY_U_k, authorLabelEN);

% (4) η=1, k=48固定 + 所持おもり（厳密非減少）
[p4V, p4TY] = solveStrictNoDecrease( ...
    eta0, k_fixed_48, m_g_list_owned, omega_deg_list, omega_rad_list, ...
    x_mm, r_eff_mm, theta_shaft, F_Votta, F_TY, ...
    DeltaF_sign, tau_arm_amp_1g, useRipplePct);

pick4 = pickBetterOfTwo( ...
    p4V.metric, p4V.m_g, p4V.omega_deg, p4V.k, 'Votta', ...
    p4TY.metric,p4TY.m_g,p4TY.omega_deg,p4TY.k, authorLabelEN);

% (5) 損失ηで必要おもり（簡易補償）: m_required = m(η=1)/η
eta_list = Tsum_all.eta;
m0 = pick1.m_g;
m_req = m0 ./ eta_list;

% 所持おもりで足りる最小値（足りなければNaN）
m_owned = m_g_list_owned(:)';
m_pick_owned = nan(size(m_req));
for i=1:numel(m_req)
    idx = find(m_owned >= m_req(i), 1, 'first');
    if ~isempty(idx)
        m_pick_owned(i) = m_owned(idx);
    end
end

% 必要トルク(N·m)に変換（アーム根元の重力トルク振幅）
% tau_arm_amp_1g は Nmm/g → Nmにするには /1000
tau_req_Nm = (tau_arm_amp_1g .* m_req) ./ 1000;               % [N·m]
tau_pick_owned_Nm = (tau_arm_amp_1g .* m_pick_owned) ./ 1000; % [N·m]（NaNあり）

Tcomp = table(eta_list, m_req, m_pick_owned, tau_req_Nm, tau_pick_owned_Nm, ...
    'VariableNames', {'eta','m_required_g','m_required_owned_g','tau_required_Nm','tau_required_owned_Nm'});

Tpicks = table( ...
    (1:5)', ...
    {'η=1・条件なし（理想）'; ...
     'η=1・ばね力より減少しない（厳密，JIS k_list）'; ...
     'η=1・k=48固定・所持おもり（最適）'; ...
     'η=1・k=48固定・所持おもり（厳密非減少）'; ...
     '損失η→必要おもり（補償計算）'}, ...
    {pick1.model; pick2.model; pick3.model; pick4.model; '計算'}, ...
    [eta0; eta0; eta0; eta0; NaN], ...
    [pick1.k; pick2.k; pick3.k; pick4.k; NaN], ...
    [pick1.omega_deg; pick2.omega_deg; pick3.omega_deg; pick4.omega_deg; NaN], ...
    [pick1.m_g; pick2.m_g; pick3.m_g; pick4.m_g; NaN], ...
    [pick1.metric; pick2.metric; pick3.metric; pick4.metric; NaN], ...
    'VariableNames', {'No','内容','採用','eta','k','omega_deg','m_g','metric'});

paperXlsx = fullfile(paperTblDir, '論文用_重要結果.xlsx');
if exist(paperXlsx,'file'); delete(paperXlsx); end
writetable(Tpicks, paperXlsx, 'Sheet', 'picks');
writetable(Tcomp,  paperXlsx, 'Sheet', 'mass_and_torque_compensation');

TstrictJIS = table( ...
    {'Votta'; authorLabelEN}, ...
    [p2V.m_g; p2TY.m_g], ...
    [p2V.omega_deg; p2TY.omega_deg], ...
    [p2V.k; p2TY.k], ...
    [p2V.metric; p2TY.metric], ...
    'VariableNames', {'Model','m_g','omega_deg','k','metric'});
writetable(TstrictJIS, paperXlsx, 'Sheet', 'strict_details_JIS');

Tstrict48 = table( ...
    {'Votta'; authorLabelEN}, ...
    [p4V.m_g; p4TY.m_g], ...
    [p4V.omega_deg; p4TY.omega_deg], ...
    [p4V.k; p4TY.k], ...
    [p4V.metric; p4TY.metric], ...
    'VariableNames', {'Model','m_g','omega_deg','k','metric'});
writetable(Tstrict48, paperXlsx, 'Sheet', 'strict_details_k48');

saveTableAsPNG(Tpicks, fullfile(paperFigDir,'論文用_重要結果.png'), [1400, 320], 12);

% 損失ηと必要おもり
fig = figure('Color','w','Visible','off'); hold on;
plot(eta_list, m_req, 'LineWidth', 2.0);
grid on;
xlabel('伝達効率 η');
ylabel('必要おもり m_{required} [g]');
title('損失ηに対する必要おもり（m_{required}=m_{η=1}/η）');
saveFigPNG(fig, outPngDir, '損失ηと必要おもり.png', [], false);
    saveFigPNG(fig, paperFigDir, '損失ηと必要おもり.png');

% 損失ηと必要トルク（N·m）
fig = figure('Color','w','Visible','off'); hold on;
plot(eta_list, tau_req_Nm, 'LineWidth', 2.0);
grid on;
xlabel('伝達効率 η');
ylabel('必要トルク \tau_{required} [N·m]');
title('損失ηに対する必要トルク（\tau_{required}=\tau_{η=1}/η）');
saveFigPNG(fig, outPngDir, '損失ηと必要トルク.png', [], false);
    saveFigPNG(fig, paperFigDir, '損失ηと必要トルク.png');

fprintf('\nPaper XLSX saved to: %s\n', paperXlsx);
end


%% ============================ ★Ripple compare outputs =================
function makeRippleCompareOutputs( ...
    paperTblDir, paperFigDir, outPngDir, outCsvDir, ...
    x_mm, r_eff_mm, theta_shaft, ...
    F_Votta, F_TY, ...
    DeltaF_sign, tau_arm_amp_1g, ...
    k_list_JIS, K_USE_MIN, K_USE_MAX, ...
    m_g_list_all, omega_deg_list, omega_rad_list, ...
    m_g_list_owned, k_fixed_48, ...
    Tsum_all, Tsum_k48_owned, ...
    authorLabelEN, authorLabelJP, ...
    dpi, showFigures, savePNG, saveCSV)

eta_list = 0.60:0.05:1.00; % 0.05刻み % 0.05刻み
positiveFractionThresh = 0.95; % increasing判定で許容する正の割合しきい値

eta0 = 1.00;

% ---- 理想（効率無視）: k を 1..200 の整数として自由選択（JIS制約なし）
k_list_ideal = K_USE_MIN:1:K_USE_MAX;

% ---- (A) 理想・最適（η=1，k自由）
[Tsum_ideal, ~] = runSweep( ...
    eta0, k_list_ideal, m_g_list_all, omega_deg_list, omega_rad_list, ...
    x_mm, r_eff_mm, theta_shaft, F_Votta, F_TY, ...
    DeltaF_sign, tau_arm_amp_1g, true, ...
    0.95, false, authorLabelEN); %#ok<NASGU>
rowIdeal = Tsum_ideal;

bestIdealV  = struct('m_g', rowIdeal.V_U_m_g,  'omega_deg', rowIdeal.V_U_omega_deg,  'k', rowIdeal.V_U_k,  'metric', rowIdeal.V_U_metric);
bestIdealTY = struct('m_g', rowIdeal.TY_U_m_g, 'omega_deg', rowIdeal.TY_U_omega_deg, 'k', rowIdeal.TY_U_k, 'metric', rowIdeal.TY_U_metric);

% ---- (B) 理想・非減少（厳密）: min(ΔF)>=0
[pIdealV_strict, pIdealTY_strict] = solveStrictNoDecrease( ...
    eta0, k_list_ideal, m_g_list_all, omega_deg_list, omega_rad_list, ...
    x_mm, r_eff_mm, theta_shaft, F_Votta, F_TY, ...
    DeltaF_sign, tau_arm_amp_1g, true);

% ---- (C) JIS再現・最適（η=1，kはJIS生成リスト）
rowJIS = Tsum_all(Tsum_all.eta==eta0, :);
if isempty(rowJIS)
    error('Tsum_all に eta=1.00 の行がありません。');
end
bestJISV  = struct('m_g', rowJIS.V_U_m_g,  'omega_deg', rowJIS.V_U_omega_deg,  'k', rowJIS.V_U_k,  'metric', rowJIS.V_U_metric);
bestJISTY = struct('m_g', rowJIS.TY_U_m_g, 'omega_deg', rowJIS.TY_U_omega_deg, 'k', rowJIS.TY_U_k, 'metric', rowJIS.TY_U_metric);

% ---- (D) JIS再現・非減少（厳密）
[pJISV_strict, pJISTY_strict] = solveStrictNoDecrease( ...
    eta0, k_list_JIS, m_g_list_all, omega_deg_list, omega_rad_list, ...
    x_mm, r_eff_mm, theta_shaft, F_Votta, F_TY, ...
    DeltaF_sign, tau_arm_amp_1g, true);

% ---- (E) k=48・最適（η=1，所持おもり）
row48 = Tsum_k48_owned(Tsum_k48_owned.eta==eta0, :);
if isempty(row48)
    error('Tsum_k48_owned に eta=1.00 の行がありません。');
end
best48V  = struct('m_g', row48.V_U_m_g,  'omega_deg', row48.V_U_omega_deg,  'k', row48.V_U_k,  'metric', row48.V_U_metric);
best48TY = struct('m_g', row48.TY_U_m_g, 'omega_deg', row48.TY_U_omega_deg, 'k', row48.TY_U_k, 'metric', row48.TY_U_metric);

% ---- (F) k=48・非減少（厳密，所持おもり）
[p48V_strict, p48TY_strict] = solveStrictNoDecrease( ...
    eta0, k_fixed_48, m_g_list_owned, omega_deg_list, omega_rad_list, ...
    x_mm, r_eff_mm, theta_shaft, F_Votta, F_TY, ...
    DeltaF_sign, tau_arm_amp_1g, true);

% ---- リップル率計算（7シナリオ×2モデル）
sc = { ...
    'ばねのみ', ...
    '理想（効率無視）・最適', ...
    'JIS再現・最適', ...
    '理想（効率無視）・非減少（厳密）', ...
    'JIS再現・非減少（厳密）', ...
    'k=48・最適（所持おもり）', ...
    'k=48・非減少（厳密，所持おもり）'};

rows = [];

% 1) ばねのみ
rows = [rows; rippleRowSpringOnly(sc{1}, 'Votta', eta0, F_Votta)];
rows = [rows; rippleRowSpringOnly(sc{1}, authorLabelEN, eta0, F_TY)];

% 2) 理想・最適
rows = [rows; rippleRowMechanism(sc{2}, 'Votta', eta0, bestIdealV,  F_Votta, x_mm, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g)];
rows = [rows; rippleRowMechanism(sc{2}, authorLabelEN, eta0, bestIdealTY, F_TY,    x_mm, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g)];

% 3) JIS再現・最適
rows = [rows; rippleRowMechanism(sc{3}, 'Votta', eta0, bestJISV,  F_Votta, x_mm, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g)];
rows = [rows; rippleRowMechanism(sc{3}, authorLabelEN, eta0, bestJISTY, F_TY, x_mm, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g)];

% 4) 理想・非減少
rows = [rows; rippleRowMechanism(sc{4}, 'Votta', eta0, pIdealV_strict,  F_Votta, x_mm, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g)];
rows = [rows; rippleRowMechanism(sc{4}, authorLabelEN, eta0, pIdealTY_strict, F_TY, x_mm, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g)];

% 5) JIS再現・非減少
rows = [rows; rippleRowMechanism(sc{5}, 'Votta', eta0, pJISV_strict,  F_Votta, x_mm, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g)];
rows = [rows; rippleRowMechanism(sc{5}, authorLabelEN, eta0, pJISTY_strict, F_TY, x_mm, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g)];

% 6) k=48・最適
rows = [rows; rippleRowMechanism(sc{6}, 'Votta', eta0, best48V,  F_Votta, x_mm, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g)];
rows = [rows; rippleRowMechanism(sc{6}, authorLabelEN, eta0, best48TY, F_TY, x_mm, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g)];

% 7) k=48・非減少
rows = [rows; rippleRowMechanism(sc{7}, 'Votta', eta0, p48V_strict,  F_Votta, x_mm, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g)];
rows = [rows; rippleRowMechanism(sc{7}, authorLabelEN, eta0, p48TY_strict, F_TY, x_mm, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g)];

TRipple = struct2table(rows);

% ---- 保存（別ファイル）
rippleXlsx = fullfile(paperTblDir, 'リップル率_比較.xlsx');
if exist(rippleXlsx,'file'); delete(rippleXlsx); end
writetable(TRipple, rippleXlsx, 'Sheet', 'compare');

% 見やすい横持ち（シナリオ行，モデル列）
Twide = makeWideRipple(TRipple, authorLabelEN);
writetable(Twide, rippleXlsx, 'Sheet', 'compare_wide');

if saveCSV
    writetable(TRipple, fullfile(outCsvDir, 'リップル率_比較.csv'));
end

% ---- グラフ（比較）
if savePNG
    fig = newFig(showFigures);
    [cats, yV, yTY] = buildRipplePctForPlot(TRipple, authorLabelEN);
    Y = [yV(:), yTY(:)];
    bar(categorical(cats), Y);

    addBarValueLabels(gca);   % ← ここに追加

    grid on;
    ylabel('リップル率 [%] = 100*(max-min)/|mean|');
    title('リップル率の比較（指定7条件）');
    legend({'Votta', authorLabelJP}, 'Location', 'best');
    saveFigPNG(fig, outPngDir, 'リップル率_比較.png', [], false);
    saveFigPNG(fig, paperFigDir, 'リップル率_比較.png');
end


fprintf('\nRipple comparison XLSX saved to: %s\n', rippleXlsx);% =========================================================================
% [方針B] ここでの makeEtaSweepCompareOutputs は重複計算になり，刻み不一致でプロットエラーの原因にもなるため無効化しました．
% 代わりに makeRequestedFileSets が条件別フォルダに ηスイープ表と図を保存します．
% =========================================================================


end


function makeRequestedFileSets(paperTblDir, paperFigDir, ...
    x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, ...
    eta_list, ...
    Tsum_ideal_all, Tsum_ideal_owned, TperMass_ideal_owned, ...
    Tsum_JIS_all,   Tsum_JIS_owned,   TperMass_JIS_owned, ...
    Tsum_k48_all,   Tsum_k48_owned,   TperMass_k48_owned, ...
    authorLabelEN, showFigures)
% =========================================================================
% ユーザー指定のフォルダ構成で図と表を出力する
%  - 標準状態：単純ばね力 + リップル率の各種比較
%  - 理想状態：理想k範囲での最適解と比較図
%  - JIS規格 ：JIS kリストでの最適解と比較図
%  - 歯数48  ：k=48固定での最適解と比較図
% =========================================================================

if showFigures
    vis = 'on';
else
    vis = 'off';
end

% --- sub folders ---
figStd   = fullfile(paperFigDir, '標準状態');
tblStd   = fullfile(paperTblDir, '標準状態');
figIdeal = fullfile(paperFigDir, '理想状態');
tblIdeal = fullfile(paperTblDir, '理想状態');
figJIS   = fullfile(paperFigDir, 'JIS規格');
tblJIS   = fullfile(paperTblDir, 'JIS規格');
figK48   = fullfile(paperFigDir, '歯数48');
tblK48   = fullfile(paperTblDir, '歯数48');

ensureDir(figStd);   ensureDir(tblStd);
ensureDir(figIdeal); ensureDir(tblIdeal);
ensureDir(figJIS);   ensureDir(tblJIS);
ensureDir(figK48);   ensureDir(tblK48);

% --- spring forces ---
[~, F_Votta, F_Tsuchiya] = springForcesOnGrid(x_mm, spring);

% =========================================================================
% 標準状態
% =========================================================================

% 単純なばね力
plotSimpleSpringForces(x_mm, F_Votta, F_Tsuchiya, figStd, vis);

% リップル率：効率ごと（最適解）
plotRippleVsEta(Tsum_ideal_all, '理想状態', figStd, vis, 'ideal');
plotRippleVsEta(Tsum_JIS_all,   'JIS規格',  figStd, vis, 'jis');
plotRippleVsEta(Tsum_k48_all,   '歯数48',   figStd, vis, 'k48');

% リップル率：トルクごと（最適解）
plotRippleVsTorque(Tsum_ideal_all, mech, '理想状態', figStd, vis, 'ideal');
plotRippleVsTorque(Tsum_JIS_all,   mech, 'JIS規格',  figStd, vis, 'jis');
plotRippleVsTorque(Tsum_k48_all,   mech, '歯数48',   figStd, vis, 'k48');

% リップル率：所持おもりごと（各おもり固定での最良）
plotRippleVsEtaByOwnedMass(TperMass_ideal_owned, '理想状態', figStd, vis, 'ideal');
plotRippleVsEtaByOwnedMass(TperMass_JIS_owned,   'JIS規格',  figStd, vis, 'jis');
plotRippleVsEtaByOwnedMass(TperMass_k48_owned,   '歯数48',   figStd, vis, 'k48');

% 表（標準状態まとめ）
try
    stdXlsx = fullfile(tblStd, '標準状態_まとめ.xlsx');
    writetable(Tsum_ideal_all, stdXlsx, 'Sheet', '理想_全');
    writetable(Tsum_JIS_all,   stdXlsx, 'Sheet', 'JIS_全');
    writetable(Tsum_k48_all,   stdXlsx, 'Sheet', '歯数48_全');
    if ~isempty(TperMass_ideal_owned) && height(TperMass_ideal_owned)>0
        writetable(TperMass_ideal_owned, stdXlsx, 'Sheet', '理想_所持_おもり別');
    end
    if ~isempty(TperMass_JIS_owned) && height(TperMass_JIS_owned)>0
        writetable(TperMass_JIS_owned, stdXlsx, 'Sheet', 'JIS_所持_おもり別');
    end
    if ~isempty(TperMass_k48_owned) && height(TperMass_k48_owned)>0
        writetable(TperMass_k48_owned, stdXlsx, 'Sheet', '歯数48_所持_おもり別');
    end
catch
end

% =========================================================================
% 理想状態ファイル
% =========================================================================
makeScenarioFileSet('理想状態', figIdeal, tblIdeal, ...
    x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
    Tsum_ideal_all, Tsum_ideal_owned, authorLabelEN, vis);

% =========================================================================
% JIS規格ファイル
% =========================================================================
makeScenarioFileSet('JIS規格', figJIS, tblJIS, ...
    x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
    Tsum_JIS_all, Tsum_JIS_owned, authorLabelEN, vis);

% =========================================================================
% 歯数48ファイル
% =========================================================================
makeScenarioFileSet('歯数48', figK48, tblK48, ...
    x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
    Tsum_k48_all, Tsum_k48_owned, authorLabelEN, vis);

end


function makeScenarioFileSet(scnNameJP, figDir, tblDir, ...
    x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
    Tsum_all, Tsum_owned, authorLabelEN, vis)
% =========================================================================
% シナリオ別の要求図を出力する
% =========================================================================

% --- tables ---
try
    scnXlsx = fullfile(tblDir, [scnNameJP '_まとめ.xlsx']);
    writetable(Tsum_all,   scnXlsx, 'Sheet', '全おもり');
    writetable(Tsum_owned, scnXlsx, 'Sheet', '所持おもり');
catch
end

% --- spring forces ---
[~, F_Votta, F_Tsuchiya] = springForcesOnGrid(x_mm, spring);

% 1) 効率0.6..1のすべてで単純ばね力との比較（条件なし）
plotForceCompareAllEta(x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
    Tsum_all, 'U', figDir, [scnNameJP '_単純ばね力比較_条件なし'], vis);

% 2) 効率0.6..1のすべてで単純ばね力との比較（元より増加）
plotForceCompareAllEta(x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
    Tsum_all, 'I', figDir, [scnNameJP '_単純ばね力比較_元より増加'], vis);

% 3) 効率に対する最適な重り（全おもり，条件なし）
plotBestParamVsEta(Tsum_all, 'U', 'm', scnNameJP, figDir, vis);

% 4) 効率に対する最適な重り（全おもり，元より増加）
plotBestParamVsEta(Tsum_all, 'I', 'm', scnNameJP, figDir, vis);

% 5) 効率に対する最適な所持おもり（条件なし）
plotBestParamVsEta(Tsum_owned, 'U', 'm', [scnNameJP '_所持おもり'], figDir, vis);

% 6) 効率に対する最適な所持おもり（元より増加）
plotBestParamVsEta(Tsum_owned, 'I', 'm', [scnNameJP '_所持おもり'], figDir, vis);

% 7) 効率に対する最適なリップル率（条件なし）
plotBestParamVsEta(Tsum_all, 'U', 'metric', scnNameJP, figDir, vis);

% 8) 効率に対する最適なリップル率（元より増加）
plotBestParamVsEta(Tsum_all, 'I', 'metric', scnNameJP, figDir, vis);

% 9) 効率に対する最適な開始位相（条件なし）
plotBestParamVsEta(Tsum_all, 'U', 'omega', scnNameJP, figDir, vis);

% 10) 効率に対する最適な開始位相（元より増加）
plotBestParamVsEta(Tsum_all, 'I', 'omega', scnNameJP, figDir, vis);

% 参考：単純ばね力
plotSimpleSpringForces(x_mm, F_Votta, F_Tsuchiya, figDir, vis);

end


function plotSimpleSpringForces(x_mm, F_Votta, F_Tsuchiya, outDir, vis)
fig = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 1200 720]);
plot(x_mm, F_Votta, 'LineWidth', 2); hold on;
plot(x_mm, F_Tsuchiya, 'LineWidth', 2);
grid on;
xlabel('x [mm]');
ylabel('Force [N]');
title('Spring-only force');
legend({'Votta model', 'Tsuchiya model'}, 'Location', 'best');
saveFigPair(fig, outDir, '単純なばね力');
end


function plotRippleVsEta(Tsum, scnNameJP, outDir, vis, tag)
eta = Tsum.eta;

% 条件なし
fig = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 1200 720]);
plot(eta, Tsum.V_U_metric, 'LineWidth', 2); hold on;
plot(eta, Tsum.TY_U_metric, 'LineWidth', 2);
grid on;
xlabel('eta');
ylabel('Ripple');
title([scnNameJP ' リップル率 vs 効率 条件なし']);
legend({'Votta model', 'Tsuchiya model'}, 'Location', 'best');
saveFigPNG(fig, outDir, [tag '_リップル率_vs_効率_条件なし.png']);

% 元より増加
fig = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 1200 720]);
plot(eta, Tsum.V_I_metric, 'LineWidth', 2); hold on;
plot(eta, Tsum.TY_I_metric, 'LineWidth', 2);
grid on;
xlabel('eta');
ylabel('Ripple');
title([scnNameJP ' リップル率 vs 効率 元より増加']);
legend({'Votta model', 'Tsuchiya model'}, 'Location', 'best');
saveFigPNG(fig, outDir, [tag '_リップル率_vs_効率_元より増加.png']);

end


function plotRippleVsTorque(Tsum, mech, scnNameJP, outDir, vis, tag)
eta = Tsum.eta;

% 条件なし
tauV  = calcArmTorqueAmpNm(mech, Tsum.V_U_m_g);
tauTY = calcArmTorqueAmpNm(mech, Tsum.TY_U_m_g);

fig = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 1200 720]);
plot(tauV,  Tsum.V_U_metric,  '-o', 'LineWidth', 2); hold on;
plot(tauTY, Tsum.TY_U_metric, '-o', 'LineWidth', 2);
grid on;
xlabel('Torque amplitude [N m]');
ylabel('Ripple');
title([scnNameJP ' リップル率 vs トルク 条件なし']);
legend({'Votta model', 'Tsuchiya model'}, 'Location', 'best');
saveFigPNG(fig, outDir, [tag '_リップル率_vs_トルク_条件なし.png']);

% 元より増加
tauV  = calcArmTorqueAmpNm(mech, Tsum.V_I_m_g);
tauTY = calcArmTorqueAmpNm(mech, Tsum.TY_I_m_g);

fig = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 1200 720]);
plot(tauV,  Tsum.V_I_metric,  '-o', 'LineWidth', 2); hold on;
plot(tauTY, Tsum.TY_I_metric, '-o', 'LineWidth', 2);
grid on;
xlabel('Torque amplitude [N m]');
ylabel('Ripple');
title([scnNameJP ' リップル率 vs トルク 元より増加']);
legend({'Votta model', 'Tsuchiya model'}, 'Location', 'best');
saveFigPNG(fig, outDir, [tag '_リップル率_vs_トルク_元より増加.png']);

end


function plotRippleVsEtaByOwnedMass(TperMass, scnNameJP, outDir, vis, tag)
if isempty(TperMass) || height(TperMass)==0
    return;
end

m_list = unique(TperMass.m_g);
eta_list = unique(TperMass.eta);

% Votta 条件なし
fig = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 1200 720]); hold on;
for i = 1:numel(m_list)
    m = m_list(i);
    Ti = TperMass(TperMass.m_g==m,:);
    [~,ord] = sort(Ti.eta);
    plot(Ti.eta(ord), Ti.V_U_metric(ord), '-o', 'LineWidth', 1.5);
end
grid on;
xlabel('eta');
ylabel('Ripple');
title(['Ripple ratio vs efficiency, Votta, unconstrained, ' scnNameJP]);
legend(compose('%dg', m_list), 'Location', 'bestoutside');
saveFigPair(fig, outDir, [tag '_所持おもり別_リップル率_vs_効率_Votta_条件なし.png']);

% 土屋 条件なし
fig = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 1200 720]); hold on;
for i = 1:numel(m_list)
    m = m_list(i);
    Ti = TperMass(TperMass.m_g==m,:);
    [~,ord] = sort(Ti.eta);
    plot(Ti.eta(ord), Ti.TY_U_metric(ord), '-o', 'LineWidth', 1.5);
end
grid on;
xlabel('eta');
ylabel('Ripple');
title(['Ripple ratio vs efficiency, Tsuchiya, unconstrained, ' scnNameJP]);
legend(compose('%dg', m_list), 'Location', 'bestoutside');
saveFigPNG(fig, outDir, [tag '_所持おもり別_リップル率_vs_効率_土屋_条件なし.png']);

% Votta 元より増加
fig = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 1200 720]); hold on;
for i = 1:numel(m_list)
    m = m_list(i);
    Ti = TperMass(TperMass.m_g==m,:);
    [~,ord] = sort(Ti.eta);
    plot(Ti.eta(ord), Ti.V_I_metric(ord), '-o', 'LineWidth', 1.5);
end
grid on;
xlabel('eta');
ylabel('Ripple');
title([scnNameJP ' 所持おもり別 リップル率 vs 効率 Votta式 元より増加']);
legend(compose('%dg', m_list), 'Location', 'bestoutside');
saveFigPNG(fig, outDir, [tag '_所持おもり別_リップル率_vs_効率_Votta_元より増加.png']);

% 土屋 元より増加
fig = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 1200 720]); hold on;
for i = 1:numel(m_list)
    m = m_list(i);
    Ti = TperMass(TperMass.m_g==m,:);
    [~,ord] = sort(Ti.eta);
    plot(Ti.eta(ord), Ti.TY_I_metric(ord), '-o', 'LineWidth', 1.5);
end
grid on;
xlabel('eta');
ylabel('Ripple');
title([scnNameJP ' 所持おもり別 リップル率 vs 効率 土屋式 元より増加']);
legend(compose('%dg', m_list), 'Location', 'bestoutside');
saveFigPNG(fig, outDir, [tag '_所持おもり別_リップル率_vs_効率_土屋_元より増加.png']);

end


function plotBestParamVsEta(Tsum, constraintTag, what, scnNameJP, outDir, vis)
eta = Tsum.eta;

switch what
    case 'm'
        if constraintTag=='U'
            yV = Tsum.V_U_m_g;  yTY = Tsum.TY_U_m_g;
            suffix = '最適重り_条件なし';
        else
            yV = Tsum.V_I_m_g;  yTY = Tsum.TY_I_m_g;
            suffix = '最適重り_元より増加';
        end
        ylab = 'm [g]';
    case 'metric'
        if constraintTag=='U'
            yV = Tsum.V_U_metric; yTY = Tsum.TY_U_metric;
            suffix = '最適リップル率_条件なし';
        else
            yV = Tsum.V_I_metric; yTY = Tsum.TY_I_metric;
            suffix = '最適リップル率_元より増加';
        end
        ylab = 'Ripple';
    case 'omega'
        if constraintTag=='U'
            yV = Tsum.V_U_omega_deg; yTY = Tsum.TY_U_omega_deg;
            suffix = '最適開始位相_条件なし';
        else
            yV = Tsum.V_I_omega_deg; yTY = Tsum.TY_I_omega_deg;
            suffix = '最適開始位相_元より増加';
        end
        ylab = 'ω [deg]';
    otherwise
        return;
end

fig = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 1200 720]);
plot(eta, yV,  '-o', 'LineWidth', 2); hold on;
plot(eta, yTY, '-o', 'LineWidth', 2);
grid on;
xlabel('eta');
ylabel(ylab);
title([scnNameJP ' ' suffix]);
legend({'Votta model', 'Tsuchiya model'}, 'Location', 'best');
saveFigPNG(fig, outDir, [scnNameJP '_' suffix '.png']);

end


function plotForceCompareAllEta(x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
    Tsum, constraintTag, outDir, baseName, vis)
% constraintTag: 'U' or 'I'

[~, F_Votta, F_Tsuchiya] = springForcesOnGrid(x_mm, spring);

% compute all curves
[YV, YTY] = computeAllEtaForceCurves(x_mm, r_eff_mm, theta_shaft, mech, DeltaF_sign, eta_list, Tsum, constraintTag, F_Votta, F_Tsuchiya);

fig = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 1400 780]);
plot(x_mm, F_Votta, 'LineWidth', 3); hold on;
plot(x_mm, F_Tsuchiya, 'LineWidth', 3);

% overlay all eta
for i = 1:numel(eta_list)
    if all(isnan(YV(:,i))) || all(isnan(YTY(:,i)))
        continue;
    end
    plot(x_mm, YV(:,i),  'LineWidth', 1);
    plot(x_mm, YTY(:,i), 'LineWidth', 1);
end

grid on;
xlabel('x [mm]');
ylabel('Force [N]');
title('All curves across efficiency eta = 0.60 to 1.00');
legend({'Spring Votta', 'Spring Tsuchiya'}, 'Location', 'best');
saveFigPair(fig, outDir, [baseName '_全η_全曲線.png']);

% envelope（見やすい版）
fig = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 1400 780]);
plot(x_mm, F_Votta, 'LineWidth', 3); hold on;
plot(x_mm, F_Tsuchiya, 'LineWidth', 3);

% Votta envelope
if ~isempty(YV)
    yMin = min(YV, [], 2, 'omitnan');
    yMax = max(YV, [], 2, 'omitnan');
    fill([x_mm(:); flipud(x_mm(:))], [yMin; flipud(yMax)], [0 0 0], 'FaceAlpha', 0.08, 'EdgeColor', 'none'); hold on;
end

% Tsuchiya envelope
if ~isempty(YTY)
    yMin = min(YTY, [], 2, 'omitnan');
    yMax = max(YTY, [], 2, 'omitnan');
    fill([x_mm(:); flipud(x_mm(:))], [yMin; flipud(yMax)], [0 0 0], 'FaceAlpha', 0.08, 'EdgeColor', 'none'); hold on;
end

grid on;
xlabel('x [mm]');
ylabel('Force [N]');
title('Envelope across efficiency eta = 0.60 to 1.00');
legend({'Spring Votta', 'Spring Tsuchiya'}, 'Location', 'best');
saveFigPair(fig, outDir, [baseName '_全η_包絡.png']);

end


function [YV, YTY] = computeAllEtaForceCurves(x_mm, r_eff_mm, theta_shaft, mech, DeltaF_sign, eta_list, Tsum, constraintTag, F_Votta, F_Tsuchiya)
nX = numel(x_mm);
nE = numel(eta_list);
YV  = nan(nX, nE);
YTY = nan(nX, nE);

for i = 1:nE
    eta = eta_list(i);

    if constraintTag=='U'
        mV  = Tsum.V_U_m_g(i);  omV  = Tsum.V_U_omega_deg(i);  kV  = Tsum.V_U_k(i);
        mTY = Tsum.TY_U_m_g(i); omTY = Tsum.TY_U_omega_deg(i); kTY = Tsum.TY_U_k(i);
    else
        mV  = Tsum.V_I_m_g(i);  omV  = Tsum.V_I_omega_deg(i);  kV  = Tsum.V_I_k(i);
        mTY = Tsum.TY_I_m_g(i); omTY = Tsum.TY_I_omega_deg(i); kTY = Tsum.TY_I_k(i);
    end

    if ~isnan(mV) && ~isnan(omV) && ~isnan(kV) && isfinite(mV) && isfinite(omV) && isfinite(kV)
        YV(:,i)  = computeFtotalCurve(kV, mV, omV, eta, x_mm, F_Votta, r_eff_mm, theta_shaft, DeltaF_sign, mech.tau_arm_amp_1g);
    end

    if ~isnan(mTY) && ~isnan(omTY) && ~isnan(kTY) && isfinite(mTY) && isfinite(omTY) && isfinite(kTY)
        YTY(:,i) = computeFtotalCurve(kTY, mTY, omTY, eta, x_mm, F_Tsuchiya, r_eff_mm, theta_shaft, DeltaF_sign, mech.tau_arm_amp_1g);
    end
end

end


function tauNm = calcArmTorqueAmpNm(mech, m_g)
% m_g: [g]
% mech.tau_arm_amp_1g: [Nmm] per 1g
tauNm = (mech.tau_arm_amp_1g .* m_g) ./ 1000; % Nmm -> N*m
end


function ensureDir(d)
if ~exist(d, 'dir')
    mkdir(d);
end
end
function s = rippleRowSpringOnly(scenario, model, eta, F)
[r, pkpk, meanF] = calcRipple1D(F);
s = struct();
s.Scenario = scenario;
s.Model = model;
s.Constraint = 'SpringOnly';
s.eta = eta;
s.k = NaN;
s.m_g = NaN;
s.omega_deg = NaN;
s.Mean_N = meanF;
s.PeakToPeak_N = pkpk;
s.RippleRatio = r;
s.RipplePct = 100*r;
end

function s = rippleRowMechanism(scenario, model, eta, best, Fspring, x_mm, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g)
% best: struct with fields m_g, omega_deg, k, metric（metricは未使用）
if ~isfinite(best.metric)
    s = struct();
    s.Scenario = scenario;
    s.Model = model;
    s.Constraint = 'NoFeasible';
    s.eta = eta;
    s.k = NaN;
    s.m_g = NaN;
    s.omega_deg = NaN;
    s.Mean_N = NaN;
    s.PeakToPeak_N = NaN;
    s.RippleRatio = inf;
    s.RipplePct = inf;
    return;
end

k = best.k;
m_g = best.m_g;
omega_deg = best.omega_deg;
omega_rad = omega_deg*pi/180;

theta_arm = theta_shaft ./ k;
tau_arm = (tau_arm_amp_1g * m_g) .* sin(theta_arm + omega_rad); % Nmm
tau_shaft = (eta .* tau_arm) ./ k;                             % Nmm
DeltaF = tau_shaft ./ r_eff_mm;                                % N
Ftot = Fspring + DeltaF_sign .* DeltaF;

[r, pkpk, meanF] = calcRipple1D(Ftot);

s = struct();
s.Scenario = scenario;
s.Model = model;
s.Constraint = 'WithMechanism';
s.eta = eta;
s.k = k;
s.m_g = m_g;
s.omega_deg = omega_deg;
s.Mean_N = meanF;
s.PeakToPeak_N = pkpk;
s.RippleRatio = r;
s.RipplePct = 100*r;
end

function Twide = makeWideRipple(TR, authorLabelEN)
% Scenario をキーにして Votta / TY の RipplePct を横持ちにする
sc = unique(TR.Scenario, 'stable');
V = nan(numel(sc),1);
T = nan(numel(sc),1);
for i=1:numel(sc)
    sub = TR(strcmp(TR.Scenario, sc{i}), :);
    for j=1:height(sub)
        if strcmp(sub.Model{j}, 'Votta')
            V(i) = sub.RipplePct(j);
        elseif strcmp(sub.Model{j}, authorLabelEN)
            T(i) = sub.RipplePct(j);
        end
    end
end
Twide = table(sc, V, T, 'VariableNames', {'Scenario','Votta_RipplePct','TY_RipplePct'});
end

function [cats, yV, yTY] = buildRipplePctForPlot(TR, authorLabelEN)
sc = unique(TR.Scenario, 'stable');
yV = nan(numel(sc),1);
yTY = nan(numel(sc),1);
for i=1:numel(sc)
    sub = TR(strcmp(TR.Scenario, sc{i}), :);
    for j=1:height(sub)
        if strcmp(sub.Model{j}, 'Votta')
            yV(i) = sub.RipplePct(j);
        elseif strcmp(sub.Model{j}, authorLabelEN)
            yTY(i) = sub.RipplePct(j);
        end
    end
end
cats = sc;
end


function pick = pickBetterOfTwo(met1,m1,o1,k1,model1, met2,m2,o2,k2,model2)
if met1 <= met2
    pick.model = model1;
    pick.metric = met1;
    pick.m_g = m1;
    pick.omega_deg = o1;
    pick.k = k1;
else
    pick.model = model2;
    pick.metric = met2;
    pick.m_g = m2;
    pick.omega_deg = o2;
    pick.k = k2;
end
end


function [bestV_strict, bestTY_strict] = solveStrictNoDecrease( ...
    eta, k_list, m_g_list, omega_deg_list, omega_rad_list, ...
    x_mm, r_eff_mm, theta_shaft, F_Votta, F_TY, ...
    DeltaF_sign, tau_arm_amp_1g, useRipplePct)

bestV_strict  = initBest();
bestTY_strict = initBest();

mVec = reshape(m_g_list, 1, 1, []);

for k = k_list
    theta_arm = theta_shaft ./ k;
    Ssin = sin( theta_arm + reshape(omega_rad_list,1,[]) );
    tau_arm_1g = tau_arm_amp_1g .* Ssin;
    tau_shaft_1g = (eta .* tau_arm_1g) ./ k;
    DeltaF_1g = tau_shaft_1g ./ r_eff_mm; % NxO

    % 厳密条件：全xで ΔF>=0（m>0なので 1gで判定可能）
    dF_sign_1g = DeltaF_sign .* DeltaF_1g; % NxO
    okOmega = (min(dF_sign_1g, [], 1) >= 0);

    if ~any(okOmega); continue; end

    dF3  = bsxfun(@times, DeltaF_1g, mVec);
    F3V  = bsxfun(@plus, F_Votta, DeltaF_sign .* dF3);
    F3TY = bsxfun(@plus, F_TY,    DeltaF_sign .* dF3);

    metV  = calcMetric3D(F3V,  useRipplePct);
    metTY = calcMetric3D(F3TY, useRipplePct);

    metV(~okOmega,:)  = inf;
    metTY(~okOmega,:) = inf;

    bestV_strict  = updateBestFromMetric(bestV_strict,  metV,  m_g_list, omega_deg_list, k);
    bestTY_strict = updateBestFromMetric(bestTY_strict, metTY, m_g_list, omega_deg_list, k);
end
end


%% ============================ Spring formulas =========================
function [R_mm, F_Votta, F_TY] = springForcesOnGrid(x_mm, spring)
R_mm = sqrt( (spring.t_mm * (spring.ell_mm - x_mm))./pi + spring.r_core_mm^2 );
R_mm(x_mm > spring.ell_mm) = NaN;

invR0 = 1/spring.R0_mm;
invR  = 1./R_mm;

F_Votta = spring.coef .* ( (invR0^2) - (invR0 - invR).^2 );
F_TY    = spring.coef .* ( (invR0^2) - (invR0 - invR).^2 + (invR0 - 2./(R_mm + spring.r_core_mm)).^2 );
end


%% ============================ ★Ripple (1D) ===========================
function [rippleRatio, pkpk, meanF] = calcRipple1D(F)
F = F(:);
meanF = mean(F,'omitnan');
pkpk  = max(F,[],'omitnan') - min(F,[],'omitnan');
if abs(meanF) < 1e-12
    rippleRatio = inf;
else
    rippleRatio = pkpk / abs(meanF);
end
end


%% ============================ Metric on 3D ============================
function met = calcMetric3D(F3, useRipplePct)
maxF = squeeze(max(F3, [], 1));   % OxM
minF = squeeze(min(F3, [], 1));   % OxM
meanF= squeeze(mean(F3, 1));      % OxM

pkpk = maxF - minF;
if useRipplePct
    met = pkpk ./ abs(meanF);
    met(abs(meanF) < 1e-12) = inf;
else
    met = pkpk;
end
end


%% ============================ Best tracking ===========================
function b = initBest()
b.metric = inf;
b.m_g = NaN;
b.omega_deg = NaN;
b.k = NaN;
end

function best = updateBestFromMetric(best, metOxM, m_list, omega_list, k)
[minval, idx] = min(metOxM(:));
if minval < best.metric
    [oi, mi] = ind2sub(size(metOxM), idx);
    best.metric = minval;
    best.m_g = m_list(mi);
    best.omega_deg = omega_list(oi);
    best.k = k;
end
end

function printOne(nameStr, best)
fprintf('%s:\n', nameStr);
fprintf('  best m = %g g\n', best.m_g);
fprintf('  best omega(start phase) = %g deg\n', best.omega_deg);
fprintf('  best k (ratio) = %g\n', best.k);
fprintf('  metric (lower is flatter) = %.10g\n', best.metric);
end


%% ============================ Table packers ===========================
function s = packLong(eta, model, constraint, best)
s = struct();
s.eta = eta;
s.Model = model;
s.Constraint = constraint;

if isfinite(best.metric)
    s.best_m_g = best.m_g;
    s.best_omega_deg = best.omega_deg;
    s.best_k = best.k;
    s.metric = best.metric;
    s.feasible = true;
else
    s.best_m_g = NaN;
    s.best_omega_deg = NaN;
    s.best_k = NaN;
    s.metric = inf;
    s.feasible = false;
end
end

function s = packSummary(eta, bestV, bestTY, bestVinc, bestTYinc)
s = struct();
s.eta = eta;

[s.V_U_m_g, s.V_U_omega_deg, s.V_U_k, s.V_U_metric] = bestToNums(bestV);
[s.TY_U_m_g, s.TY_U_omega_deg, s.TY_U_k, s.TY_U_metric] = bestToNums(bestTY);

[s.V_I_m_g, s.V_I_omega_deg, s.V_I_k, s.V_I_metric] = bestToNums(bestVinc);
[s.TY_I_m_g, s.TY_I_omega_deg, s.TY_I_k, s.TY_I_metric] = bestToNums(bestTYinc);
end

function s = packPerMass(eta, m_g, ...
    V_U_metric, V_U_omega_deg, V_U_k, ...
    TY_U_metric, TY_U_omega_deg, TY_U_k, ...
    V_I_metric, V_I_omega_deg, V_I_k, ...
    TY_I_metric, TY_I_omega_deg, TY_I_k)
% etaごと，おもり質量ごとの最良解（各モデル，各制約）を保存するための行
s = struct();
s.eta = eta;
s.m_g = m_g;

s.V_U_metric = V_U_metric;
s.V_U_omega_deg = V_U_omega_deg;
s.V_U_k = V_U_k;

s.TY_U_metric = TY_U_metric;
s.TY_U_omega_deg = TY_U_omega_deg;
s.TY_U_k = TY_U_k;

s.V_I_metric = V_I_metric;
s.V_I_omega_deg = V_I_omega_deg;
s.V_I_k = V_I_k;

s.TY_I_metric = TY_I_metric;
s.TY_I_omega_deg = TY_I_omega_deg;
s.TY_I_k = TY_I_k;
end


function [m, om, k, met] = bestToNums(best)
if isfinite(best.metric)
    m = best.m_g;
    om = best.omega_deg;
    k = best.k;
    met = best.metric;
else
    m = NaN; om = NaN; k = NaN; met = inf;
end
end


%% ============================ Plot / Save =============================
function fig = newFig(showFigures)
if showFigures
    fig = figure('Color','w');
else
    fig = figure('Color','w','Visible','off');
end
end


function savedPath = saveFigPair(fig, outDir, fileNameJP, varargin)
% =========================================================================
% PNG と FIG を同時に保存するユーティリティ
% =========================================================================
savedPath = saveFigPNG(fig, outDir, fileNameJP, varargin{:});
try
    [~, base, ~] = fileparts(char(fileNameJP));
    if isempty(base)
        base = 'figure';
    end
    savefig(fig, fullfile(outDir, [base '.fig']));
catch
end
end


function s = tagEN_fromTagJP(tagJP)
if contains(tagJP, '非減少')
    s = 'non-decreasing';
else
    s = 'unconstrained';
end
end


function t = makeEnglishTitle_bestParamVsEta(what, constraintTag)
if constraintTag=='I'
    c = 'non-decreasing';
else
    c = 'unconstrained';
end

switch what
    case 'm'
        p = 'Best mass vs eta';
    case 'k'
        p = 'Best gear ratio k vs eta';
    case 'omega'
        p = 'Best phase omega vs eta';
    case 'tau'
        p = 'Best output torque vs eta';
    case 'metric'
        p = 'Minimum ripple ratio vs eta';
    otherwise
        p = 'Best parameter vs eta';
end
t = sprintf('%s, %s', p, c);
end


function savedPath = saveFigPNG(fig, outDir, fileNameJP, varargin)
% =========================================================================
% PNG保存ユーティリティ
% 互換性:
%   saveFigPNG(fig, outDir, fileNameJP)
%   saveFigPNG(fig, outDir, fileNameJP, dpi)
%   saveFigPNG(fig, outDir, fileNameJP, dpi, closeAfter)
%   saveFigPNG(fig, outDir, fileNameJP, dpi, showFigures, closeAfter)  旧互換
%   saveFigPNG(fig, outDir, fileNameJP, dpi, closeAfter, showFigures)  旧互換
% =========================================================================
savedPath = '';

% --- 図ハンドルの健全性確認 ---
if nargin < 3
    warning('saveFigPNG:Input', 'PNG保存に必要な入力が不足しています．');
    return;
end
if isempty(fig) || ~isgraphics(fig)
    warning('saveFigPNG:InvalidFig', 'PNG保存をスキップしました．Figure が無効です．');
    return;
end

% --- 既定値 ---
dpi = [];
showFigures = [];
closeAfter = false;

% --- 追加引数の解釈 ---
% varargin の想定
%   {dpi}
%   {dpi, closeAfter}
%   {dpi, showFigures, closeAfter}   旧互換
%   {dpi, closeAfter, showFigures}   旧互換
if ~isempty(varargin)
    if numel(varargin) >= 1
        dpi = varargin{1};
    end
    if numel(varargin) == 2
        % 2個の場合は closeAfter を優先
        if islogical(varargin{2}) || (isnumeric(varargin{2}) && isscalar(varargin{2}) && any(varargin{2}==[0 1]))
            closeAfter = logical(varargin{2});
        else
            showFigures = varargin{2};
        end
    elseif numel(varargin) >= 3
        a2 = varargin{2};
        a3 = varargin{3};
        % a2 と a3 を showFigures と closeAfter に割り当て
        if islogical(a2) || (isnumeric(a2) && isscalar(a2) && any(a2==[0 1]))
            % (dpi, closeAfter, showFigures) 形式の可能性
            closeAfter = logical(a2);
            showFigures = a3;
        else
            % (dpi, showFigures, closeAfter) 形式の可能性
            showFigures = a2;
            if islogical(a3) || (isnumeric(a3) && isscalar(a3) && any(a3==[0 1]))
                closeAfter = logical(a3);
            end
        end
    end
end

% dpi 既定
if isempty(dpi) || ~isnumeric(dpi) || ~isscalar(dpi) || dpi <= 0
    dpi = 200;
end

% showFigures 既定
if isempty(showFigures)
    % 図の現在表示状態に合わせる
    try
        showFigures = strcmpi(get(fig, 'Visible'), 'on');
    catch
        showFigures = false;
    end
else
    showFigures = logical(showFigures);
end

% closeAfter 既定
if isempty(closeAfter)
    closeAfter = false;
else
    closeAfter = logical(closeAfter);
end

% --- 出力先の用意 ---
try
    ensureDir(outDir);
catch
    warning('saveFigPNG:OutDir', 'PNG保存に失敗しました．出力フォルダを作成できません: %s', outDir);
    return;
end

% --- ファイル名整形 ---
if isempty(fileNameJP)
    fileNameJP = 'figure';
end
fileNameJP = char(fileNameJP);

% 拡張子の扱い
[~, ~, ext] = fileparts(fileNameJP);
if isempty(ext)
    fileName = [fileNameJP '.png'];
else
    fileName = fileNameJP;
end

fullPath = fullfile(outDir, fileName);

% 既存ファイルや同名ロックを避けてユニークにする
try
    fullPath = makeUniqueFilePath(fullPath);
catch
    % makeUniqueFilePath が失敗しても元のパスで試す
end

% --- 保存処理 ---
prevVis = '';
try
    prevVis = get(fig, 'Visible');
catch
end

% showFigures 指定がある場合は反映
try
    if showFigures
        set(fig, 'Visible', 'on');
    else
        set(fig, 'Visible', 'off');
    end
catch
end

savedOK = false;

% exportgraphics が使える場合
try
    exportgraphics(fig, fullPath, 'Resolution', dpi);
    savedOK = true;
catch
    savedOK = false;
end

% print のフォールバック
if ~savedOK
    try
        print(fig, fullPath, '-dpng', ['-r' num2str(dpi)]);
        savedOK = true;
    catch
        savedOK = false;
    end
end

% getframe の最終フォールバック
if ~savedOK
    try
        fr = getframe(fig);
        imwrite(fr.cdata, fullPath);
        savedOK = true;
    catch
        savedOK = false;
    end
end

% 復元
try
    if ~isempty(prevVis)
        set(fig, 'Visible', prevVis);
    end
catch
end

if ~savedOK
    warning('saveFigPNG:Failed', 'PNG保存に失敗しました: %s', fullPath);
else
    savedPath = fullPath;
end

% close 指定
if closeAfter
    try
        if isgraphics(fig)
            close(fig);
        end
    catch
    end
end
end


function outPath = makeUniqueFilePath(inPath)
% ============================================================
% 同名ファイルの上書き失敗やロックを避けるためのユーティリティ．
% inPath が存在する場合は，末尾に _01, _02 ... を付けて未使用パスを返す．
% ============================================================
    outPath = inPath;
    if ~exist(inPath, 'file')
        return;
    end
    [d, n, e] = fileparts(inPath);
    for k = 1:999
        cand = fullfile(d, sprintf('%s_%02d%s', n, k, e));
        if ~exist(cand, 'file')
            outPath = cand;
            return;
        end
    end
    cand = fullfile(d, sprintf('%s_%s%s', n, datestr(now, 'yyyymmdd_HHMMSSFFF'), e));
    if ~exist(cand, 'file')
        outPath = cand;
    else
        outPath = tempname(d);
        outPath = [outPath e];
    end
end

function saveBestPlot(best, labelStr, eta, outDir, dpi, showFigures, ...
    x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, tau_arm_amp_1g, authorLabelJP)

if ~isfinite(best.metric); return; end

[~, F_V, F_TY] = springForcesOnGrid(x_mm, spring);

isTY = contains(labelStr, 'Tsuchiya') || contains(labelStr, 'Yoshimura');

if isTY
    Fspring = F_TY;
    springName = ['ばね力のみ（' authorLabelJP '式）'];
    modelName = authorLabelJP;
else
    Fspring = F_V;
    springName = 'ばね力のみ（Votta式）';
    modelName = 'Votta';
end

k = best.k;
omega_deg = best.omega_deg;
omega_rad = omega_deg*pi/180;

theta_arm = theta_shaft ./ k;
tau_arm = (tau_arm_amp_1g * best.m_g) .* sin(theta_arm + omega_rad); % Nmm
tau_shaft = (eta .* tau_arm) ./ k;
DeltaF = tau_shaft ./ r_eff_mm;

Ftot = Fspring + DeltaF_sign .* DeltaF;

fig = newFig(showFigures); hold on;
plot(x_mm, Fspring, 'LineWidth', 2.0);
plot(x_mm, Ftot,    'LineWidth', 1.4);
grid on;
xlabel('ストローク x [mm]');
ylabel('力 [N]');
title(sprintf('合力の最適結果（%s）, η=%.2f', modelName, eta));

leg2 = sprintf('合力（m=%dg, ω=%ddeg, k=%g）', round(best.m_g), round(best.omega_deg), best.k);
legend({springName, leg2}, 'Location', 'best');

fname = makeJPName(labelStr, eta, best);
saveFigPNG(fig, outDir, fname);
end

function fname = makeJPName(labelStr, eta, best)
if contains(labelStr,'increasing')
    tag = '増やす';
else
    tag = '一定';
end
if contains(labelStr,'Votta')
    modelTag = 'Votta';
else
    modelTag = '土屋吉村';
end

kStr = sprintf('%.6g', best.k);
kStr = strrep(kStr, '.', 'p');

fname = sprintf('最適_%s_%s_効率%.2f_m%dg_omega%ddeg_k%s.png', ...
    tag, modelTag, eta, round(best.m_g), round(best.omega_deg), kStr);
end


%% ============================ Table -> PNG ============================
function saveTableAsPNG(T, pngPath, figSizeWH, fontSize)
C = table2cell(T);
C = forceCellToBasic(C);

col = T.Properties.VariableNames;
col = forceCellToBasic(col);

fig = figure('Color','w','Visible','on'); % getframe対策
fig.Position(3) = figSizeWH(1);
fig.Position(4) = figSizeWH(2);

uit = uitable(fig, 'Units','normalized','Position',[0 0 1 1]);
uit.Data = C;
uit.ColumnName = col;
uit.FontSize = fontSize;

drawnow;
frame = getframe(fig);
imwrite(frame.cdata, pngPath);
close(fig);
end

function C = forceCellToBasic(C)
if ischar(C)
    C = {C};
end
if isstring(C)
    C = cellstr(C);
end
if iscell(C)
    for i=1:numel(C)
        v = C{i};
        if isstring(v)
            C{i} = char(v);
        elseif iscategorical(v)
            C{i} = char(v);
        elseif isdatetime(v)
            C{i} = char(v);
        elseif ismissing(v)
            C{i} = '';
        end
    end
end
end


%% ============================ k list generator ========================
function make_k_list_3shaft_JIS_m1()
thisDir = fileparts(mfilename('fullpath'));
% 3軸（2段）複合歯車の比 減速比 k = (z2_driven/z1_drive) * (z4_driven/z3_drive)
% を作り、k_list と代表組合せ gear_table を MAT に保存する。

% ---- 編集OK：歯数候補（JISの手持ち・入手性に合わせて調整）----
z = [8 10 12 14 16 18 20 22 24 25 26 28 30 32 34 36 38 40 ...
     45 48 50 55 60 63 64 65 70 72 75 80 84 90 96 100 110 120 125 130 140 150 160 180 200];

% ステージの全組み合わせ（ドライブ/ドリブン）
[Z1, Z2] = ndgrid(z, z);
z1_drive = Z1(:);
z2_driven = Z2(:);

[Z3, Z4] = ndgrid(z, z);
z3_drive = Z3(:);
z4_driven = Z4(:);

n1 = numel(z1_drive);
n2 = numel(z3_drive);

% 全組み合わせを作る（n1*n2）
% ここは3.4M程度（zが43個の場合）で、初回だけ少し時間がかかります。
[I1, I2] = ndgrid(1:n1, 1:n2);

num = uint32(z2_driven(I1)) .* uint32(z4_driven(I2)); % z2*z4
den = uint32(z1_drive(I1)) .* uint32(z3_drive(I2));   % z1*z3

g = gcd(num, den);
numr = num ./ g;
denr = den ./ g;

pairs = [double(numr(:)) double(denr(:))];
[uniqPairs, ia] = unique(pairs, 'rows', 'stable');

k_value = uniqPairs(:,1) ./ uniqPairs(:,2);

% フィルタ（本体側でもするが、MATを軽くするためここでも実施）
K_USE_MIN = 1;
K_USE_MAX = 200;
ok = (k_value >= K_USE_MIN) & (k_value <= K_USE_MAX);

uniqPairs = uniqPairs(ok,:);
k_value   = k_value(ok);
ia        = ia(ok);

% 代表組合せ（uniqueの最初の出現を採用）
idx0 = ia; % numr(:) の線形index

rep_i1 = I1(idx0);
rep_i2 = I2(idx0);

rep_z1 = z1_drive(rep_i1);
rep_z2 = z2_driven(rep_i1);
rep_z3 = z3_drive(rep_i2);
rep_z4 = z4_driven(rep_i2);

% ソート
[ks, ord] = sort(k_value);
k_list = ks(:)';

uniqPairs = uniqPairs(ord,:);
rep_z1 = rep_z1(ord);
rep_z2 = rep_z2(ord);
rep_z3 = rep_z3(ord);
rep_z4 = rep_z4(ord);

gear_table = table( ...
    ks, ...
    uniqPairs(:,1), uniqPairs(:,2), ...
    rep_z1, rep_z2, rep_z3, rep_z4, ...
    'VariableNames', {'k_value','k_num','k_den','z1_drive','z2_driven','z3_drive','z4_driven'});

save(fullfile(thisDir,'k_list_3shaft_JIS_m1.mat'), 'k_list', 'gear_table');

fprintf('Saved: %s\n', fullfile(thisDir,'k_list_3shaft_JIS_m1.mat'));
fprintf('k count = %d\n', numel(k_list));
end

function addBarValueLabels(ax, fmt)
% 棒グラフの各棒の上に数値ラベルを表示する
% ax  : axes handle（省略時 gca）
% fmt : 表示フォーマット（省略時 '%.2f'）

if nargin < 1 || isempty(ax)
    ax = gca;
end
if nargin < 2 || isempty(fmt)
    fmt = '%.2f';
end

bars = findobj(ax, 'Type', 'Bar');
if isempty(bars)
    return;
end

% findobj は描画順と逆になりがちなので反転
bars = flipud(bars);

yl = ylim(ax);
dy = 0.01 * max(1, abs(yl(2) - yl(1)));

holdState = ishold(ax);
hold(ax, 'on');

for bi = 1:numel(bars)
    b = bars(bi);

    % 新しめの MATLAB は XEndPoints, YEndPoints が使える
    if isprop(b, 'XEndPoints') && isprop(b, 'YEndPoints')
        x = b.XEndPoints;
        y = b.YEndPoints;
        yv = b.YData;
    else
        % 古い MATLAB 用のフォールバック
        yv = b.YData;
        x = b.XData;
        y = yv;
    end

    if isempty(x) || isempty(y)
        continue;
    end

    for j = 1:numel(y)
        if isnan(y(j)) || isinf(y(j))
            continue;
        end

        if y(j) >= 0
            va = 'bottom';
            yText = y(j) + dy;
        else
            va = 'top';
            yText = y(j) - dy;
        end

        text(ax, x(j), yText, sprintf(fmt, yv(j)), ...
            'HorizontalAlignment', 'center', ...
            'VerticalAlignment', va, ...
            'Interpreter', 'none', ...
            'Clipping', 'on');
    end
end

if ~holdState
    hold(ax, 'off');
end
end

function addRippleBox(fig, seriesNames, seriesData, pos)
% 図の中にリップル率などをまとめたテキストボックスを追加する
% fig         : figure handle
% seriesNames : 文字列セル配列
% seriesData  : データのセル配列（各要素がベクトル）
% pos         : annotation textbox の位置 [x y w h]（省略可）

if nargin < 4 || isempty(pos)
    pos = [0.02 0.02 0.55 0.22];
end

n = numel(seriesData);
lines = cell(n+1, 1);
lines{1} = 'RippleRatio = (max-min)/|mean|';

for i = 1:n
    [r, pkpk, meanF] = calcRipple1D(seriesData{i});
    if isinf(r)
        lines{i+1} = sprintf('%s: mean=%.4g, pkpk=%.4g, ripple=Inf', seriesNames{i}, meanF, pkpk);
    else
        lines{i+1} = sprintf('%s: mean=%.4g, pkpk=%.4g, ripple=%.4g (%.2f%%)', seriesNames{i}, meanF, pkpk, r, 100*r);
    end
end

annotation(fig, 'textbox', pos, ...
    'String', lines, ...
    'Interpreter', 'none', ...
    'FitBoxToText', 'off', ...
    'BackgroundColor', 'w', ...
    'EdgeColor', 'k');
end



%% ===================== Added: K48 plot pair and param trends =====================

%% ===================== k=48用：縦軸範囲の前計算 =====================
function yLim = computeGlobalYLimK48(Tsum_k48, x_mm, r_eff_mm, theta_shaft, spring, DeltaF_sign, tau_arm_amp_1g)
% k=48固定で保存する全グラフの縦軸を統一するために，全ケースの力の最小最大を集計する

[~, F_V, F_TY] = springForcesOnGrid(x_mm, spring);

yMin = inf;
yMax = -inf;

for i = 1:height(Tsum_k48)
    eta = Tsum_k48.eta(i);

    % 4ケース：最適と増やす，Vottaと土屋-吉村
    cands = { ...
        struct('metric',Tsum_k48.V_U_metric(i),  'm_g',Tsum_k48.V_U_m_g(i),  'omega_deg',Tsum_k48.V_U_omega_deg(i),  'k',Tsum_k48.V_U_k(i)),  false; ...
        struct('metric',Tsum_k48.TY_U_metric(i), 'm_g',Tsum_k48.TY_U_m_g(i), 'omega_deg',Tsum_k48.TY_U_omega_deg(i), 'k',Tsum_k48.TY_U_k(i)), true; ...
        struct('metric',Tsum_k48.V_I_metric(i),  'm_g',Tsum_k48.V_I_m_g(i),  'omega_deg',Tsum_k48.V_I_omega_deg(i),  'k',Tsum_k48.V_I_k(i)),  false; ...
        struct('metric',Tsum_k48.TY_I_metric(i), 'm_g',Tsum_k48.TY_I_m_g(i), 'omega_deg',Tsum_k48.TY_I_omega_deg(i), 'k',Tsum_k48.TY_I_k(i)), true  ...
        };

    for j = 1:size(cands,1)
        best = cands{j,1};
        isTY = cands{j,2};

        if ~isfinite(best.metric)
            continue;
        end

        if isTY
            Fspring = F_TY;
        else
            Fspring = F_V;
        end

        k = best.k;
        omega_rad = best.omega_deg*pi/180;

        theta_arm = theta_shaft ./ k;
        tau_arm = (tau_arm_amp_1g * best.m_g) .* sin(theta_arm + omega_rad); % Nmm
        tau_shaft = (eta .* tau_arm) ./ k;                                 % Nmm
        DeltaF = tau_shaft ./ r_eff_mm;                                    % N

        Ftot = Fspring + DeltaF_sign .* DeltaF;

        yMin = min(yMin, min([Fspring(:); Ftot(:)], [], 'omitnan'));
        yMax = max(yMax, max([Fspring(:); Ftot(:)], [], 'omitnan'));
    end
end

if ~isfinite(yMin) || ~isfinite(yMax)
    yLim = [];
    return;
end

dy = 0.05 * max(1, abs(yMax - yMin));
yLim = [yMin - dy, yMax + dy];
end

function saveBestPlotPairK48(bestV, bestTY, tagStr, eta, outDir, dpi, showFigures, ...
    x_mm, r_eff_mm, theta_shaft, spring, DeltaF_sign, tau_arm_amp_1g, authorLabelJP, yLimGlobal)
% k=48固定の結果を1枚の図にまとめて保存する．
% 上段: Votta，下段: 土屋-吉村
% 下段にテキスト領域を確保し，x軸ラベルが隠れないようにする．

if nargin < 15
    yLimGlobal = [];
end

% ばね力
[~, F_V, F_TY] = springForcesOnGrid(x_mm, spring);

% ---- Votta 合力 ----
okV = isfinite(bestV.metric);
Ftot_V = nan(size(F_V));
if okV
    kV = bestV.k;
    omegaV = bestV.omega_deg*pi/180;
    theta_arm_V = theta_shaft ./ kV;
    tau_arm_V = (tau_arm_amp_1g * bestV.m_g) .* sin(theta_arm_V + omegaV); % Nmm
    tau_shaft_V = (eta .* tau_arm_V) ./ kV;                                % Nmm
    DeltaF_V = tau_shaft_V ./ r_eff_mm;                                     % N
    Ftot_V = F_V + DeltaF_sign .* DeltaF_V;
end

% ---- 土屋-吉村 合力 ----
okTY = isfinite(bestTY.metric);
Ftot_TY = nan(size(F_TY));
if okTY
    kT = bestTY.k;
    omegaT = bestTY.omega_deg*pi/180;
    theta_arm_T = theta_shaft ./ kT;
    tau_arm_T = (tau_arm_amp_1g * bestTY.m_g) .* sin(theta_arm_T + omegaT); % Nmm
    tau_shaft_T = (eta .* tau_arm_T) ./ kT;                                 % Nmm
    DeltaF_T = tau_shaft_T ./ r_eff_mm;                                      % N
    Ftot_TY = F_TY + DeltaF_sign .* DeltaF_T;
end

% ---- 縦軸範囲 ----
if isempty(yLimGlobal)
    yMin = min([F_V(:); F_TY(:); Ftot_V(:); Ftot_TY(:)], [], 'omitnan');
    yMax = max([F_V(:); F_TY(:); Ftot_V(:); Ftot_TY(:)], [], 'omitnan');
    dy = 0.06 * max(1, abs(yMax - yMin));
    yLim = [yMin - dy, yMax + dy];
else
    yLim = yLimGlobal;
end

% ---- 図 ----
fig = newFig(showFigures);
set(fig, 'Position', [100 80 1200 900]);

t = tiledlayout(fig, 3, 1, 'TileSpacing', 'loose', 'Padding', 'loose');

% Votta
ax1 = nexttile(t, 1); hold(ax1, 'on'); box(ax1, 'on');
plot(ax1, x_mm, F_V, 'LineWidth', 2.0);
if okV
    plot(ax1, x_mm, Ftot_V, 'LineWidth', 1.6);
end
grid(ax1, 'on');
xlabel(ax1, 'ストローク x [mm]');
ylabel(ax1, '力 [N]');
title(ax1, sprintf('Votta %s', tagStr));
ylim(ax1, yLim);

% 土屋-吉村
ax2 = nexttile(t, 2); hold(ax2, 'on'); box(ax2, 'on');
plot(ax2, x_mm, F_TY, 'LineWidth', 2.0);
if okTY
    plot(ax2, x_mm, Ftot_TY, 'LineWidth', 1.6);
end
grid(ax2, 'on');
xlabel(ax2, 'ストローク x [mm]');
ylabel(ax2, '力 [N]');
title(ax2, sprintf('%s %s', authorLabelJP, tagStr));
ylim(ax2, yLim);

% テキスト領域
ax3 = nexttile(t, 3);
axis(ax3, 'off');

lines = {};
lines{end+1} = 'RippleRatio = (max-min)/|mean|';

% Votta
[rS_V, pkpkS_V, meanS_V] = calcRipple1D(F_V);
lines{end+1} = sprintf('Votta ばね力: mean=%.4g, pkpk=%.4g, ripple=%.5g (%.2f%%)', meanS_V, pkpkS_V, rS_V, 100*rS_V);
if okV
    [rT_V, pkpkT_V, meanT_V] = calcRipple1D(Ftot_V);
    lines{end+1} = sprintf('Votta 合力:  mean=%.4g, pkpk=%.4g, ripple=%.5g (%.2f%%),  m=%dg, ω=%ddeg', meanT_V, pkpkT_V, rT_V, 100*rT_V, round(bestV.m_g), round(bestV.omega_deg));
else
    lines{end+1} = 'Votta 合力:  No feasible solution';
end

% 土屋-吉村
[rS_T, pkpkS_T, meanS_T] = calcRipple1D(F_TY);
lines{end+1} = sprintf('%s ばね力: mean=%.4g, pkpk=%.4g, ripple=%.5g (%.2f%%)', authorLabelJP, meanS_T, pkpkS_T, rS_T, 100*rS_T);
if okTY
    [rT_T, pkpkT_T, meanT_T] = calcRipple1D(Ftot_TY);
    lines{end+1} = sprintf('%s 合力:  mean=%.4g, pkpk=%.4g, ripple=%.5g (%.2f%%),  m=%dg, ω=%ddeg', authorLabelJP, meanT_T, pkpkT_T, rT_T, 100*rT_T, round(bestTY.m_g), round(bestTY.omega_deg));
else
    lines{end+1} = sprintf('%s 合力:  No feasible solution', authorLabelJP);
end

text(ax3, 0.01, 0.98, lines, ...
    'Units', 'normalized', ...
    'VerticalAlignment', 'top', ...
    'Interpreter', 'none', ...
    'FontName', 'Consolas', ...
    'FontSize', 10);

sgtitle(fig, sprintf('k=48固定，%s，効率 η=%.2f', tagStr, eta));

fname = sprintf('k48_%s_効率%.2f.png', tagStr, eta);
saveFigPNG(fig, outDir, fname);

end

function plotK48ParamsVsEta(Tsum_k48, outDir, dpi, showFigures, authorLabelJP)
% k=48固定の結果について，ηに対する m と ω の依存を図で保存します．

eta = Tsum_k48.eta;

% ---- m vs eta ----
fig = newFig(showFigures); hold on;
plot(eta, Tsum_k48.V_U_m_g,  '-o', 'LineWidth', 1.6);
plot(eta, Tsum_k48.TY_U_m_g, '-o', 'LineWidth', 1.6);
plot(eta, Tsum_k48.V_I_m_g,  '--o', 'LineWidth', 1.6);
plot(eta, Tsum_k48.TY_I_m_g, '--o', 'LineWidth', 1.6);
grid on;
xlabel('伝達効率 η');
ylabel('最適おもり m [g]');
title('k=48固定：ηに対する最適おもり m の変化');
legend({'Votta 最適','土屋-吉村 最適','Votta 増やす','土屋-吉村 増やす'}, 'Location','best');
saveFigPNG(fig, outDir, 'k48_m_vs_eta.png');

% ---- omega vs eta ----
fig = newFig(showFigures); hold on;
plot(eta, Tsum_k48.V_U_omega_deg,  '-o', 'LineWidth', 1.6);
plot(eta, Tsum_k48.TY_U_omega_deg, '-o', 'LineWidth', 1.6);
plot(eta, Tsum_k48.V_I_omega_deg,  '--o', 'LineWidth', 1.6);
plot(eta, Tsum_k48.TY_I_omega_deg, '--o', 'LineWidth', 1.6);
grid on;
xlabel('伝達効率 η');
ylabel('開始位相 ω [deg]');
title('k=48固定：ηに対する開始位相 ω の変化');
legend({'Votta 最適','土屋-吉村 最適','Votta 増やす','土屋-吉村 増やす'}, 'Location','best');
saveFigPNG(fig, outDir, 'k48_omega_vs_eta.png');

% ---- metric vs eta（参考）----
fig = newFig(showFigures); hold on;
plot(eta,RutoInfToNaN(Tsum_k48.V_U_metric),  '-o', 'LineWidth', 1.6);
plot(eta, RutoInfToNaN(Tsum_k48.TY_U_metric), '-o', 'LineWidth', 1.6);
plot(eta, RutoInfToNaN(Tsum_k48.V_I_metric),  '--o', 'LineWidth', 1.6);
plot(eta, RutoInfToNaN(Tsum_k48.TY_I_metric), '--o', 'LineWidth', 1.6);
grid on;
xlabel('伝達効率 η');
ylabel('metric = RippleRatio');
title('k=48固定：ηに対する metric の変化');
legend({'Votta 最適','土屋-吉村 最適','Votta 増やす','土屋-吉村 増やす'}, 'Location','best');
saveFigPNG(fig, outDir, 'k48_metric_vs_eta.png');

end


function y = RutoInfToNaN(y)
y(~isfinite(y)) = NaN;
end


function makeEtaSweepCompareOutputs( ...
    paperTblDir, paperFigDir, eta_list, ...
    x_mm, r_eff_mm, theta_shaft, ...
    F_Votta, F_TY, ...
    DeltaF_sign, tau_arm_amp_1g, ...
    k_list_JIS, K_USE_MIN, K_USE_MAX, ...
    m_g_list_all, omega_deg_list, omega_rad_list, ...
    m_g_list_owned, k_fixed_48, ...
    Tsum_all, Tsum_k48_owned, ...
    positiveFractionThresh, ...
    authorLabelEN, authorLabelJP, ...
    dpi, showFigures)

% =========================================================================
% 依頼追加出力：
% - 理想状態／JIS遵守／歯数48の各条件で，
%   η=0.6〜1.0の全てについて
%   単純ばね力との比較グラフ，最適m，最適リップル率，最適開始位相のη依存を保存する．
% すべて paperFigDir と paperTblDir に保存する．
% =========================================================================

if ~exist(paperFigDir,'dir'); mkdir(paperFigDir); end
if ~exist(paperTblDir,'dir'); mkdir(paperTblDir); end

% ---- まず，単純ばね力（理論のみ） ----
fig0 = newFig(showFigures);
set(fig0,'Position',[120 80 1200 520]);
ax0 = axes(fig0); hold(ax0,'on'); grid(ax0,'on');
plot(ax0, x_mm, F_Votta, 'LineWidth', 2.0);
plot(ax0, x_mm, F_TY,    'LineWidth', 2.0);
xlabel(ax0,'引き出し長さ x [mm]');
ylabel(ax0,'ばね力 F [N]');
title(ax0,'単純なばね力（理論のみ）');
legend(ax0, {'Votta','土屋-吉村'}, 'Location','best');
saveFigPNG(fig0, paperFigDir, 'ばね理論_単純ばね力.png');

% ---- 理想状態（k=K_USE_MIN..K_USE_MAX）をη全域で計算 ----
k_list_ideal = K_USE_MIN:K_USE_MAX;

fprintf('\n[Paper] ηスイープ（理想状態）を計算します：k=%d..%d, m=%d..%d, ω=%d..%d\n', ...
    min(k_list_ideal), max(k_list_ideal), min(m_g_list_all), max(m_g_list_all), min(omega_deg_list), max(omega_deg_list));

[Tsum_ideal, Tlong_ideal] = runSweep( ...
    eta_list, k_list_ideal, m_g_list_all, omega_deg_list, omega_rad_list, ...
    x_mm, r_eff_mm, theta_shaft, F_Votta, F_TY, ...
    DeltaF_sign, tau_arm_amp_1g, true, ...
    positiveFractionThresh, false, authorLabelEN);

% ---- 表保存 ----
saveEtaSweepTables(paperTblDir, '理想_効率スイープ_最適値.xlsx', Tsum_ideal, Tlong_ideal);
saveEtaSweepTables(paperTblDir, 'JIS_効率スイープ_最適値.xlsx', Tsum_all, []);
saveEtaSweepTables(paperTblDir, '歯数48_効率スイープ_最適値.xlsx', Tsum_k48_owned, []);

% ---- 図保存：力比較（条件なし／増加） ----
saveEtaSweepForceCompareFigure(paperFigDir, '理想_条件なし_ばね力比較.png', ...
    '理想状態 条件なし', eta_list, 'U', Tsum_ideal, ...
    x_mm, F_Votta, F_TY, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g, dpi, showFigures);

saveEtaSweepForceCompareFigure(paperFigDir, '理想_増加_ばね力比較.png', ...
    '理想状態 増加', eta_list, 'I', Tsum_ideal, ...
    x_mm, F_Votta, F_TY, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g, dpi, showFigures);

saveEtaSweepForceCompareFigure(paperFigDir, 'JIS_条件なし_ばね力比較.png', ...
    'JIS規格遵守 条件なし', eta_list, 'U', Tsum_all, ...
    x_mm, F_Votta, F_TY, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g, dpi, showFigures);

saveEtaSweepForceCompareFigure(paperFigDir, 'JIS_増加_ばね力比較.png', ...
    'JIS規格遵守 増加', eta_list, 'I', Tsum_all, ...
    x_mm, F_Votta, F_TY, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g, dpi, showFigures);

saveEtaSweepForceCompareFigure(paperFigDir, '歯数48_条件なし_ばね力比較.png', ...
    '歯数48 条件なし', eta_list, 'U', Tsum_k48_owned, ...
    x_mm, F_Votta, F_TY, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g, dpi, showFigures);

saveEtaSweepForceCompareFigure(paperFigDir, '歯数48_増加_ばね力比較.png', ...
    '歯数48 増加', eta_list, 'I', Tsum_k48_owned, ...
    x_mm, F_Votta, F_TY, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g, dpi, showFigures);

% ---- 図保存：最適パラメータのη依存 ----
plotEtaSweepParamsSeparated(paperFigDir, '理想', eta_list, Tsum_ideal, dpi, showFigures);
plotEtaSweepParamsSeparated(paperFigDir, 'JIS', eta_list, Tsum_all, dpi, showFigures);
plotEtaSweepParamsSeparated(paperFigDir, '歯数48', eta_list, Tsum_k48_owned, dpi, showFigures);

fprintf('[Paper] ηスイープの図と表を保存しました：%s，%s\n', paperFigDir, paperTblDir);

end



function saveEtaSweepTables(paperTblDir, fileName, Tsum, Tlong)
% 表は paperTblDir に保存．Tlong が空なら summary のみ保存．
fullPath = fullfile(paperTblDir, fileName);
if exist(fullPath,'file'); delete(fullPath); end

try
    writetable(Tsum, fullPath, 'Sheet','summary');
catch
    writetable(Tsum, fullPath);
end

if ~isempty(Tlong)
    try
        writetable(Tlong, fullPath, 'Sheet','long');
    catch
        % Excelが無い環境などではSheet指定が失敗する場合がある．その場合は別ファイルに退避．
        writetable(Tlong, fullfile(paperTblDir, ['long_',fileName]));
    end
end

end


function saveEtaSweepForceCompareFigure(outDir, fileName, figTitle, eta_list, modeUI, Tsum, ...
    x_mm, F_Votta, F_TY, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g, dpi, showFigures)

% modeUI: 'U' または 'I'
% 2段（Votta／土屋-吉村）で，単純ばね力と，ηスイープ最適合力の包絡を重ねて保存する．

fig = newFig(showFigures);
set(fig,'Position',[110 70 1200 900]);

t = tiledlayout(fig, 2, 1, 'TileSpacing','compact', 'Padding','compact');

% ---- Votta ----
ax1 = nexttile(t,1);
plotForceEnvelope(ax1, eta_list, modeUI, 'V', Tsum, x_mm, F_Votta, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g);
title(ax1, [figTitle,'：Votta']);
ylabel(ax1,'力 F [N]');
grid(ax1,'on');

% ---- 土屋-吉村 ----
ax2 = nexttile(t,2);
plotForceEnvelope(ax2, eta_list, modeUI, 'TY', Tsum, x_mm, F_TY, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g);
title(ax2, [figTitle,'：土屋-吉村']);
xlabel(ax2,'引き出し長さ x [mm]');
ylabel(ax2,'力 F [N]');
grid(ax2,'on');

sgtitle(t, [figTitle,'  η=',sprintf('%.2f',eta_list(1)),'〜',sprintf('%.2f',eta_list(end))], 'FontWeight','bold');

saveFigPNG(fig, outDir, fileName);

end


function plotForceEnvelope(ax, eta_list, modeUI, modelKey, Tsum, x_mm, Fspring, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g)
% 各ηでの最適合力を計算し，min／mean／maxを描く．
% modelKey: 'V' or 'TY'

hold(ax,'on');

% パラメータ列名
if strcmpi(modelKey,'V')
    prefix = 'V_';
else
    prefix = 'TY_';
end

if strcmpi(modeUI,'U')
    mid = 'U_';
else
    mid = 'I_';
end

col_k     = [prefix, mid, 'k'];
col_m     = [prefix, mid, 'm_g'];
col_omega = [prefix, mid, 'omega_deg'];

N = numel(x_mm);
E = numel(eta_list);
Fmat = nan(N,E);

for i = 1:E
    eta = eta_list(i);

    % Tsumはηごとに1行ある想定．見つからない場合はNaNでスキップ．
    row = Tsum(abs(Tsum.eta - eta) < 1e-9, :);
    if isempty(row); continue; end

    k = row.(col_k); m_g = row.(col_m); omega_deg = row.(col_omega);

    if ~isfinite(k) || ~isfinite(m_g) || ~isfinite(omega_deg); continue; end

    Fmat(:,i) = computeFtotalCurve(k, m_g, omega_deg, eta, x_mm, Fspring, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g);
end

Fmin  = min(Fmat,[],2,'omitnan');
Fmax  = max(Fmat,[],2,'omitnan');
Fmean = mean(Fmat,2,'omitnan');

plot(ax, x_mm, Fspring, 'LineWidth', 2.0);
plot(ax, x_mm, Fmean,  'LineWidth', 1.7);
plot(ax, x_mm, Fmin,   '--', 'LineWidth', 1.1);
plot(ax, x_mm, Fmax,   '--', 'LineWidth', 1.1);

legend(ax, {'単純ばね力','最適合力 平均','最適合力 最小','最適合力 最大'}, 'Location','best');

end


function plotEtaSweepParamsSeparated(outDir, scenarioTag, eta_list, Tsum, dpi, showFigures)
% 依頼通り，条件なし と 増加 を分けて，m，リップル率，開始位相を保存する．

% ---- m ----
saveParamFigure(outDir, [scenarioTag,'_条件なし_最適重り.png'], ...
    [scenarioTag,' 条件なし 最適重り'], eta_list, ...
    Tsum.V_U_m_g, Tsum.TY_U_m_g, 'm [g]', dpi, showFigures);

saveParamFigure(outDir, [scenarioTag,'_増加_最適重り.png'], ...
    [scenarioTag,' 増加 最適重り'], eta_list, ...
    Tsum.V_I_m_g, Tsum.TY_I_m_g, 'm [g]', dpi, showFigures);

% ---- ripple ----
saveParamFigure(outDir, [scenarioTag,'_条件なし_最適リップル率.png'], ...
    [scenarioTag,' 条件なし 最適リップル率'], eta_list, ...
    100*Tsum.V_U_metric, 100*Tsum.TY_U_metric, 'Ripple [%]', dpi, showFigures);

saveParamFigure(outDir, [scenarioTag,'_増加_最適リップル率.png'], ...
    [scenarioTag,' 増加 最適リップル率'], eta_list, ...
    100*Tsum.V_I_metric, 100*Tsum.TY_I_metric, 'Ripple [%]', dpi, showFigures);

% ---- omega ----
saveParamFigure(outDir, [scenarioTag,'_条件なし_最適開始位相.png'], ...
    [scenarioTag,' 条件なし 最適開始位相'], eta_list, ...
    Tsum.V_U_omega_deg, Tsum.TY_U_omega_deg, '開始位相 ω [deg]', dpi, showFigures);

saveParamFigure(outDir, [scenarioTag,'_増加_最適開始位相.png'], ...
    [scenarioTag,' 増加 最適開始位相'], eta_list, ...
    Tsum.V_I_omega_deg, Tsum.TY_I_omega_deg, '開始位相 ω [deg]', dpi, showFigures);

end


function saveParamFigure(outDir, fileName, figTitle, eta_list, yV, yTY, yLabel, dpi, showFigures)

fig = newFig(showFigures);
set(fig,'Position',[150 100 1100 600]);
ax = axes(fig); hold(ax,'on'); grid(ax,'on');
plot(ax, eta_list, yV,  '-o', 'LineWidth', 1.8);
plot(ax, eta_list, yTY, '-o', 'LineWidth', 1.8);
xlabel(ax,'伝達効率 η [-]');
ylabel(ax,yLabel);
title(ax, figTitle);
legend(ax, {'Votta','土屋-吉村'}, 'Location','best');
saveFigPNG(fig, outDir, fileName);

end


function Ftot = computeFtotalCurve(k, m_g, omega_deg, eta, x_mm, Fspring, r_eff_mm, theta_shaft, DeltaF_sign, tau_arm_amp_1g)
% パラメータから合力曲線を計算する．
if ~isfinite(k) || ~isfinite(m_g) || ~isfinite(omega_deg) || k <= 0
    Ftot = nan(size(x_mm));
    return;
end

omega_rad = deg2rad(omega_deg);
theta_arm = theta_shaft ./ k;                 % [rad]
Ssin = sin(theta_arm + omega_rad);            % [-]
tau_shaft_1g = eta .* tau_arm_amp_1g .* Ssin ./ k;  % [N*mm/g]
DeltaF_1g = tau_shaft_1g ./ r_eff_mm;         % [N/g]
dF = m_g .* DeltaF_1g;                        % [N]
Ftot = Fspring + DeltaF_sign .* dF;           % [N]
end


%% =======================================================================
%% ========== v26_OUTSTYLE: 条件1〜7フォルダ構成で出力する関数群 ===========
%% =======================================================================

function makeRequestedFileSets_COND(paperTblDir, paperFigDir, ...
    x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, ...
    eta_list, ...
    Tsum_ideal_all, Tsum_ideal_owned, TperMass_ideal_owned, ...
    Tsum_JIS_all,   Tsum_JIS_owned,   TperMass_JIS_owned, ...
    Tsum_k48_all,   Tsum_k48_owned,   TperMass_k48_owned, ...
    authorLabelEN, showFigures)
% =========================================================================
% 出力フォーマットを「条件1〜7」ベースに統一する
%
% 条件1: ばね単体（Votta / 土屋）
% 条件2: 理想状態（k=1..200, 条件なし）        = Tsum_ideal_all, constraint 'U'
% 条件3: 理想状態（k=1..200, 非減少）          = Tsum_ideal_all, constraint 'I'
% 条件4: JIS規格（k=JISリスト, 条件なし）       = Tsum_JIS_all,   constraint 'U'
% 条件5: JIS規格（k=JISリスト, 非減少）         = Tsum_JIS_all,   constraint 'I'
% 条件6: k=48固定（所持おもり, 条件なし）       = Tsum_k48_owned, constraint 'U'
% 条件7: k=48固定（所持おもり, 非減少）         = Tsum_k48_owned, constraint 'I'
%
% それぞれについて
%  - η=1 の出力波形とリップル率（ばね単体との比較）
%  - η=0.60〜1.00 の各ηで最良解の m, k, ω, τ, Ripple を表とグラフで出力
% =========================================================================

if showFigures
    vis = 'on';
else
    vis = 'off';
end

% --- spring forces ---
[~, F_Votta, F_Tsuchiya] = springForcesOnGrid(x_mm, spring);

% =========================================================================
% 条件1: ばね単体
% =========================================================================
figC1 = fullfile(paperFigDir, '条件1_ばね単体');
tblC1 = fullfile(paperTblDir, '条件1_ばね単体');
ensureDir(figC1); ensureDir(tblC1);

% ばね力波形
try
    plotSimpleSpringForces(x_mm, F_Votta, F_Tsuchiya, figC1, vis);
catch
end

% ばね単体リップル率
try
    [rV, pkpkV, meanV] = calcRipple1D(F_Votta);
    [rT, pkpkT, meanT] = calcRipple1D(F_Tsuchiya);

    Tspring = table( ...
        {'Votta'; authorLabelEN}, ...
        [meanV; meanT], ...
        [pkpkV; pkpkT], ...
        [rV; rT], ...
        'VariableNames', {'Model','Mean_N','PeakToPeak_N','RippleRatio'} );

    writetable(Tspring, fullfile(tblC1, '条件1_ばね単体_リップル率.xlsx'), 'Sheet', 'spring');
catch
end

% =========================================================================
% 条件2: 理想（条件なし）
% =========================================================================
figC2 = fullfile(paperFigDir, '条件2_理想_最適');
tblC2 = fullfile(paperTblDir, '条件2_理想_最適');
ensureDir(figC2); ensureDir(tblC2);

exportOneConditionSet('条件2_理想_最適', figC2, tblC2, ...
    x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
    Tsum_ideal_all, 'U', authorLabelEN, vis, true);

% =========================================================================
% 条件3: 理想（非減少）
% =========================================================================
figC3 = fullfile(paperFigDir, '条件3_理想_非減少');
tblC3 = fullfile(paperTblDir, '条件3_理想_非減少');
ensureDir(figC3); ensureDir(tblC3);

exportOneConditionSet('条件3_理想_非減少', figC3, tblC3, ...
    x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
    Tsum_ideal_all, 'I', authorLabelEN, vis, true);

% =========================================================================
% 条件4: JIS（条件なし）
% =========================================================================
figC4 = fullfile(paperFigDir, '条件4_JIS_最適');
tblC4 = fullfile(paperTblDir, '条件4_JIS_最適');
ensureDir(figC4); ensureDir(tblC4);

exportOneConditionSet('条件4_JIS_最適', figC4, tblC4, ...
    x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
    Tsum_JIS_all, 'U', authorLabelEN, vis, true);

% =========================================================================
% 条件5: JIS（非減少）
% =========================================================================
figC5 = fullfile(paperFigDir, '条件5_JIS_非減少');
tblC5 = fullfile(paperTblDir, '条件5_JIS_非減少');
ensureDir(figC5); ensureDir(tblC5);

exportOneConditionSet('条件5_JIS_非減少', figC5, tblC5, ...
    x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
    Tsum_JIS_all, 'I', authorLabelEN, vis, true);

% =========================================================================
% 条件6: k=48（所持おもり，条件なし）
% =========================================================================
figC6 = fullfile(paperFigDir, '条件6_k48_最適');
tblC6 = fullfile(paperTblDir, '条件6_k48_最適');
ensureDir(figC6); ensureDir(tblC6);

exportOneConditionSet('条件6_k48_最適', figC6, tblC6, ...
    x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
    Tsum_k48_owned, 'U', authorLabelEN, vis, true);

% 所持おもり別 η リップル率（任意）
try
    if ~isempty(TperMass_k48_owned) && height(TperMass_k48_owned)>0
        plotRippleVsEtaByOwnedMass(TperMass_k48_owned, 'k=48', figC6, vis, 'k48');
    end
catch
end

% =========================================================================
% 条件7: k=48（所持おもり，非減少）
% =========================================================================
figC7 = fullfile(paperFigDir, '条件7_k48_非減少');
tblC7 = fullfile(paperTblDir, '条件7_k48_非減少');
ensureDir(figC7); ensureDir(tblC7);

exportOneConditionSet('条件7_k48_非減少', figC7, tblC7, ...
    x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
    Tsum_k48_owned, 'I', authorLabelEN, vis, true);

try
    if ~isempty(TperMass_k48_owned) && height(TperMass_k48_owned)>0
        plotRippleVsEtaByOwnedMass(TperMass_k48_owned, 'k=48', figC7, vis, 'k48');
    end
catch
end

end


function exportOneConditionSet(condNameJP, figDir, tblDir, ...
    x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
    Tsum, constraintTag, authorLabelEN, vis, doEta1)
% =========================================================================
% 1条件分の出力セットを作成
% =========================================================================

% 1) ベストパラメータ表（ηごと）
try
    Tbest = buildBestTableByEta(Tsum, constraintTag, mech, authorLabelEN);
    writetable(Tbest, fullfile(tblDir, [condNameJP '_最適解_η別.xlsx']), 'Sheet', 'best');
catch
end

% 2) η=0.60..1.00 出力波形比較（全η）
try
    plotForceCompareAllEta(x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
        Tsum, constraintTag, figDir, [condNameJP '_出力波形'], vis);
catch
end

% 3) η=1.00 の出力波形とリップル率比較
if doEta1
    try
        plotForceCompareEta1_COND(x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
            Tsum, constraintTag, figDir, [condNameJP '_η1_比較'], vis, authorLabelEN);

        Teta1 = buildEta1CompareTable(x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, Tsum, constraintTag, authorLabelEN);
        writetable(Teta1, fullfile(tblDir, [condNameJP '_η1_リップル比較.xlsx']), 'Sheet', 'eta1');
    catch
    end
end


% 3b) 最小リップル率となるηの図（Votta と 土屋を別々に出力）
try
    plotForceCompareBestRipple_COND(x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
        Tsum, constraintTag, figDir, condNameJP, vis, authorLabelEN);
    TbestRip = buildBestRippleTable_COND(Tsum, constraintTag, mech, authorLabelEN);
    writetable(TbestRip, fullfile(tblDir, [condNameJP '_最小リップル_最適解.xlsx']), 'Sheet', 'bestRipple');
catch
end

% 4) ηに対する最適パラメータのグラフ
try
    plotBestParamVsEta2(Tsum, constraintTag, 'm',     condNameJP, figDir, vis, mech);
    plotBestParamVsEta2(Tsum, constraintTag, 'k',     condNameJP, figDir, vis, mech);
    plotBestParamVsEta2(Tsum, constraintTag, 'omega', condNameJP, figDir, vis, mech);
    plotBestParamVsEta2(Tsum, constraintTag, 'tau',   condNameJP, figDir, vis, mech);
    plotBestParamVsEta2(Tsum, constraintTag, 'metric',condNameJP, figDir, vis, mech);
catch
end

end


function Tbest = buildBestTableByEta(Tsum, constraintTag, mech, authorLabelEN)
% =========================================================================
% ηごとに最適解（Votta / 土屋）を表にする
% 追加でトルク（アーム/出力軸）の振幅も算出して付与する
% =========================================================================

eta = Tsum.eta(:);

if constraintTag=='U'
    V_m = Tsum.V_U_m_g(:);      V_om = Tsum.V_U_omega_deg(:); V_k = Tsum.V_U_k(:);      V_met = Tsum.V_U_metric(:);
    T_m = Tsum.TY_U_m_g(:);     T_om = Tsum.TY_U_omega_deg(:);T_k = Tsum.TY_U_k(:);     T_met = Tsum.TY_U_metric(:);
    tagJP = '条件なし';
else
    V_m = Tsum.V_I_m_g(:);      V_om = Tsum.V_I_omega_deg(:); V_k = Tsum.V_I_k(:);      V_met = Tsum.V_I_metric(:);
    T_m = Tsum.TY_I_m_g(:);     T_om = Tsum.TY_I_omega_deg(:);T_k = Tsum.TY_I_k(:);     T_met = Tsum.TY_I_metric(:);
    tagJP = '非減少';
end

% torque amplitude (Nmm)
tau1g = mech.tau_arm_amp_1g; % Nmm per gram
V_tau_arm_Nm   = (tau1g .* V_m) ./ 1000;
T_tau_arm_Nm   = (tau1g .* T_m) ./ 1000;

V_tau_out_Nm   = (eta .* (tau1g .* V_m) ./ max(V_k,eps)) ./ 1000;
T_tau_out_Nm   = (eta .* (tau1g .* T_m) ./ max(T_k,eps)) ./ 1000;

Tbest = table( ...
    eta, ...
    V_m, V_k, V_om, V_tau_arm_Nm, V_tau_out_Nm, V_met, ...
    T_m, T_k, T_om, T_tau_arm_Nm, T_tau_out_Nm, T_met);

Tbest.Properties.VariableNames = { ...
    'eta', ...
    'V_m_g','V_k','V_omega_deg','V_tau_arm_Nm','V_tau_out_Nm','V_Ripple', ...
    'TY_m_g','TY_k','TY_omega_deg','TY_tau_arm_Nm','TY_tau_out_Nm','TY_Ripple'};

Tbest.Properties.Description = ['Best-by-eta (' tagJP ')  Votta and ' authorLabelEN];
end


function plotBestParamVsEta2(Tsum, constraintTag, what, titlePrefixJP, outDir, vis, mech)
eta = Tsum.eta;

switch what
    case 'm'
        if constraintTag=='U'
            yV = Tsum.V_U_m_g;  yTY = Tsum.TY_U_m_g;
            suffix = '最適重り_条件なし';
        else
            yV = Tsum.V_I_m_g;  yTY = Tsum.TY_I_m_g;
            suffix = '最適重り_非減少';
        end
        ylab = 'm [g]';

    case 'k'
        if constraintTag=='U'
            yV = Tsum.V_U_k;  yTY = Tsum.TY_U_k;
            suffix = '最適歯車比k_条件なし';
        else
            yV = Tsum.V_I_k;  yTY = Tsum.TY_I_k;
            suffix = '最適歯車比k_非減少';
        end
        ylab = 'k [-]';

    case 'omega'
        if constraintTag=='U'
            yV = Tsum.V_U_omega_deg; yTY = Tsum.TY_U_omega_deg;
            suffix = '最適開始位相_条件なし';
        else
            yV = Tsum.V_I_omega_deg; yTY = Tsum.TY_I_omega_deg;
            suffix = '最適開始位相_非減少';
        end
        ylab = 'ω [deg]';

    case 'metric'
        if constraintTag=='U'
            yV = Tsum.V_U_metric; yTY = Tsum.TY_U_metric;
            suffix = '最適リップル率_条件なし';
        else
            yV = Tsum.V_I_metric; yTY = Tsum.TY_I_metric;
            suffix = '最適リップル率_非減少';
        end
        ylab = 'Ripple';

    case 'tau'
        tau1g = mech.tau_arm_amp_1g; % Nmm/g
        if constraintTag=='U'
            mV = Tsum.V_U_m_g; kV = Tsum.V_U_k;
            mT = Tsum.TY_U_m_g; kT = Tsum.TY_U_k;
            suffix = '最適出力トルク_条件なし';
        else
            mV = Tsum.V_I_m_g; kV = Tsum.V_I_k;
            mT = Tsum.TY_I_m_g; kT = Tsum.TY_I_k;
            suffix = '最適出力トルク_非減少';
        end
        % 出力軸トルク振幅（N*m）
        yV  = (eta .* (tau1g .* mV) ./ max(kV,eps)) ./ 1000;
        yTY = (eta .* (tau1g .* mT) ./ max(kT,eps)) ./ 1000;
        ylab = 'τ_out [N·m]';

    otherwise
        return;
end

fig = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 1200 720]);
plot(eta, yV,  '-o', 'LineWidth', 2); hold on;
plot(eta, yTY, '-o', 'LineWidth', 2);
grid on;
xlabel('eta');
ylabel(ylab);
title(makeEnglishTitle_bestParamVsEta(what, constraintTag));
legend({'Votta model', 'Tsuchiya model'}, 'Location', 'best');
saveFigPair(fig, outDir, [titlePrefixJP '_' suffix '.png']);
end


function plotForceCompareEta1_COND(x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
    Tsum, constraintTag, outDir, baseName, vis, authorLabelEN)
% =========================================================================
% η=1.00 のときだけ，ばね単体と機構出力を比較して保存
% =========================================================================

% 1.00 のindex
idx = find(abs(eta_list - 1.0) < 1e-12, 1, 'first');
if isempty(idx)
    warning('η=1.00 が eta_list にありません');
    return;
end
eta = eta_list(idx);

[~, F_Votta, F_Tsuchiya] = springForcesOnGrid(x_mm, spring);

% best params
if constraintTag=='U'
    mV = Tsum.V_U_m_g(idx);  omV = Tsum.V_U_omega_deg(idx);  kV = Tsum.V_U_k(idx);
    mT = Tsum.TY_U_m_g(idx); omT = Tsum.TY_U_omega_deg(idx); kT = Tsum.TY_U_k(idx);
    tagJP = '条件なし';
else
    mV = Tsum.V_I_m_g(idx);  omV = Tsum.V_I_omega_deg(idx);  kV = Tsum.V_I_k(idx);
    mT = Tsum.TY_I_m_g(idx); omT = Tsum.TY_I_omega_deg(idx); kT = Tsum.TY_I_k(idx);
    tagJP = '非減少';
end

% compute curves
FV_out  = computeForceCurveOne(x_mm, r_eff_mm, theta_shaft, mech, DeltaF_sign, eta, mV, omV, kV, F_Votta);
FTY_out = computeForceCurveOne(x_mm, r_eff_mm, theta_shaft, mech, DeltaF_sign, eta, mT, omT, kT, F_Tsuchiya);

% ripple
[rV_s,  pkV_s,  meanV_s]  = calcRipple1D(F_Votta);
[rT_s,  pkT_s,  meanT_s]  = calcRipple1D(F_Tsuchiya);
[rV_o,  pkV_o,  meanV_o]  = calcRipple1D(FV_out);
[rT_o,  pkT_o,  meanT_o]  = calcRipple1D(FTY_out);

% plot
fig = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 1400 780]);
plot(x_mm, F_Votta,   'LineWidth', 2.5); hold on;
plot(x_mm, FV_out,    'LineWidth', 2.0);
plot(x_mm, F_Tsuchiya,'LineWidth', 2.5);
plot(x_mm, FTY_out,   'LineWidth', 2.0);
grid on;
xlabel('x [mm]');
ylabel('Force [N]');
title(sprintf('eta = 1.00, %s', tagEN_fromTagJP(tagJP)));
legend({ ...
    sprintf('Spring Votta, ripple=%.4f', rV_s), ...
    sprintf('Output Votta, ripple=%.4f', rV_o), ...
    sprintf('Spring %s, ripple=%.4f', authorLabelEN, rT_s), ...
    sprintf('Output %s, ripple=%.4f', authorLabelEN, rT_o)}, ...
    'Location', 'best');
saveFigPair(fig, outDir, [baseName '_η1.png']);
end


function Tout = buildEta1CompareTable(x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, Tsum, constraintTag, authorLabelEN)
% =========================================================================
% η=1 のばね単体と機構出力のリップル率比較表を作成
% =========================================================================
idx = find(abs(eta_list - 1.0) < 1e-12, 1, 'first');
if isempty(idx)
    Tout = table();
    return;
end
eta = eta_list(idx);

[~, F_Votta, F_Tsuchiya] = springForcesOnGrid(x_mm, spring);

if constraintTag=='U'
    mV = Tsum.V_U_m_g(idx);  omV = Tsum.V_U_omega_deg(idx);  kV = Tsum.V_U_k(idx);
    mT = Tsum.TY_U_m_g(idx); omT = Tsum.TY_U_omega_deg(idx); kT = Tsum.TY_U_k(idx);
    tagJP = '条件なし';
else
    mV = Tsum.V_I_m_g(idx);  omV = Tsum.V_I_omega_deg(idx);  kV = Tsum.V_I_k(idx);
    mT = Tsum.TY_I_m_g(idx); omT = Tsum.TY_I_omega_deg(idx); kT = Tsum.TY_I_k(idx);
    tagJP = '非減少';
end

FV_out  = computeForceCurveOne(x_mm, r_eff_mm, theta_shaft, mech, DeltaF_sign, eta, mV, omV, kV, F_Votta);
FTY_out = computeForceCurveOne(x_mm, r_eff_mm, theta_shaft, mech, DeltaF_sign, eta, mT, omT, kT, F_Tsuchiya);

[rV_s,  pkV_s,  meanV_s]  = calcRipple1D(F_Votta);
[rT_s,  pkT_s,  meanT_s]  = calcRipple1D(F_Tsuchiya);
[rV_o,  pkV_o,  meanV_o]  = calcRipple1D(FV_out);
[rT_o,  pkT_o,  meanT_o]  = calcRipple1D(FTY_out);

Model = {'Votta'; authorLabelEN};
Ripple_spring = [rV_s; rT_s];
Ripple_output = [rV_o; rT_o];
Mean_spring_N = [meanV_s; meanT_s];
Mean_output_N = [meanV_o; meanT_o];
PeakToPeak_spring_N = [pkV_s; pkT_s];
PeakToPeak_output_N = [pkV_o; pkT_o];

Tout = table(Model, Ripple_spring, Ripple_output, Mean_spring_N, Mean_output_N, PeakToPeak_spring_N, PeakToPeak_output_N);
Tout.Properties.Description = ['eta=1 compare (' tagJP ')'];
end


function Fout = computeForceCurveOne(x_mm, r_eff_mm, theta_shaft, mech, DeltaF_sign, eta, m_g, omega_deg, k, Fbase)
% =========================================================================
% ある(η,m,ω,k)に対して機構付加後の力波形を計算する
% =========================================================================
omega_rad = deg2rad(omega_deg);
theta_arm = theta_shaft ./ k;
Ssin = sin(theta_arm + omega_rad);

tau_arm_1g   = mech.tau_arm_amp_1g .* Ssin;    % Nmm/g
tau_shaft_1g = (eta .* tau_arm_1g) ./ k;       % Nmm/g
DeltaF_1g    = tau_shaft_1g ./ r_eff_mm;       % N/g

DeltaF = DeltaF_1g .* m_g;                     % N
Fout   = Fbase(:) + DeltaF_sign .* DeltaF(:);
end


function plotForceCompareBestRipple_COND(x_mm, r_eff_mm, theta_shaft, spring, mech, DeltaF_sign, eta_list, ...
    Tsum, constraintTag, outDir, condNameJP, vis, authorLabelEN)
% =========================================================================
% ηスイープの中でリップル率が最小となるケースを描く
% =========================================================================

[~, F_Votta, F_Tsuchiya] = springForcesOnGrid(x_mm, spring);

if constraintTag=='U'
    metV = Tsum.V_U_metric;      mV  = Tsum.V_U_m_g;      omV = Tsum.V_U_omega_deg;      kV  = Tsum.V_U_k;
    metT = Tsum.TY_U_metric;     mT  = Tsum.TY_U_m_g;     omT = Tsum.TY_U_omega_deg;     kT  = Tsum.TY_U_k;
    tagJP = '条件なし';
else
    metV = Tsum.V_I_metric;      mV  = Tsum.V_I_m_g;      omV = Tsum.V_I_omega_deg;      kV  = Tsum.V_I_k;
    metT = Tsum.TY_I_metric;     mT  = Tsum.TY_I_m_g;     omT = Tsum.TY_I_omega_deg;     kT  = Tsum.TY_I_k;
    tagJP = '非減少';
end

% Votta best
idxV = argminFinite_v27(metV);
if ~isempty(idxV)
    etaV = eta_list(idxV);
    FoutV = computeForceCurveOne(x_mm, r_eff_mm, theta_shaft, mech, DeltaF_sign, etaV, mV(idxV), omV(idxV), kV(idxV), F_Votta);
    [rS, ~, ~] = calcRipple1D(F_Votta);
    [rO, ~, ~] = calcRipple1D(FoutV);

    fig = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 1400 780]);
    plot(x_mm, F_Votta, 'LineWidth', 2.8); hold on;
    plot(x_mm, FoutV,   'LineWidth', 2.0);
    grid on;
    xlabel('x [mm]');
    ylabel('Force [N]');
    title(sprintf('Minimum ripple case, Votta, eta=%.2f, %s', etaV, tagEN_fromTagJP(tagJP)));
    legend({sprintf('Spring Votta, ripple=%.4f', rS), sprintf('Output Votta, ripple=%.4f', rO)}, 'Location', 'best');
    saveFigPair(fig, outDir, [condNameJP '_最小リップル_Votta.png']);
end

% Tsuchiya best
idxT = argminFinite_v27(metT);
if ~isempty(idxT)
    etaT = eta_list(idxT);
    FoutT = computeForceCurveOne(x_mm, r_eff_mm, theta_shaft, mech, DeltaF_sign, etaT, mT(idxT), omT(idxT), kT(idxT), F_Tsuchiya);
    [rS, ~, ~] = calcRipple1D(F_Tsuchiya);
    [rO, ~, ~] = calcRipple1D(FoutT);

    fig = figure('Visible', vis, 'Color', 'w', 'Position', [100 100 1400 780]);
    plot(x_mm, F_Tsuchiya, 'LineWidth', 2.8); hold on;
    plot(x_mm, FoutT,      'LineWidth', 2.0);
    grid on;
    xlabel('x [mm]');
    ylabel('Force [N]');
    title(sprintf('Minimum ripple case, Tsuchiya, eta=%.2f, %s', etaT, tagEN_fromTagJP(tagJP)));
    legend({sprintf('Spring %s, ripple=%.4f', authorLabelEN, rS), sprintf('Output %s, ripple=%.4f', authorLabelEN, rO)}, 'Location', 'best');
    saveFigPair(fig, outDir, [condNameJP '_最小リップル_Tsuchiya.png']);
end

end


function TbestRip = buildBestRippleTable_COND(Tsum, constraintTag, mech, authorLabelEN)
eta_list = Tsum.eta(:);

if constraintTag=='U'
    metV = Tsum.V_U_metric(:);      mV  = Tsum.V_U_m_g(:);      omV = Tsum.V_U_omega_deg(:);      kV  = Tsum.V_U_k(:);
    metT = Tsum.TY_U_metric(:);     mT  = Tsum.TY_U_m_g(:);     omT = Tsum.TY_U_omega_deg(:);     kT  = Tsum.TY_U_k(:);
else
    metV = Tsum.V_I_metric(:);      mV  = Tsum.V_I_m_g(:);      omV = Tsum.V_I_omega_deg(:);      kV  = Tsum.V_I_k(:);
    metT = Tsum.TY_I_metric(:);     mT  = Tsum.TY_I_m_g(:);     omT = Tsum.TY_I_omega_deg(:);     kT  = Tsum.TY_I_k(:);
end

idxV = argminFinite_v27(metV);
idxT = argminFinite_v27(metT);

tau1g = mech.tau_arm_amp_1g; % Nmm per g

Model = {};
eta   = [];
m_g   = [];
k     = [];
omega_deg = [];
tau_out_Nm = [];
ripple = [];

if ~isempty(idxV)
    Model{end+1,1} = 'Votta';
    eta(end+1,1) = eta_list(idxV);
    m_g(end+1,1) = mV(idxV);
    k(end+1,1) = kV(idxV);
    omega_deg(end+1,1) = omV(idxV);
    tau_out_Nm(end+1,1) = (eta_list(idxV) .* (tau1g .* mV(idxV)) ./ max(kV(idxV),eps)) ./ 1000;
    ripple(end+1,1) = metV(idxV);
end

if ~isempty(idxT)
    Model{end+1,1} = authorLabelEN;
    eta(end+1,1) = eta_list(idxT);
    m_g(end+1,1) = mT(idxT);
    k(end+1,1) = kT(idxT);
    omega_deg(end+1,1) = omT(idxT);
    tau_out_Nm(end+1,1) = (eta_list(idxT) .* (tau1g .* mT(idxT)) ./ max(kT(idxT),eps)) ./ 1000;
    ripple(end+1,1) = metT(idxT);
end

TbestRip = table(Model, eta, m_g, k, omega_deg, tau_out_Nm, ripple);
TbestRip.Properties.VariableNames = {'Model','eta','m_g','k','omega_deg','tau_out_Nm','RippleRatio'};
end


function idx = argminFinite_v27(x)
x = x(:);
ok = isfinite(x);
if ~any(ok)
    idx = [];
    return;
end
[~, ii] = min(x(ok));
I = find(ok);
idx = I(ii);
end

