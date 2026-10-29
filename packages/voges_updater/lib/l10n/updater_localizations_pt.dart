// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'updater_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Portuguese (`pt`).
class UpdaterLocalizationsPt extends UpdaterLocalizations {
  UpdaterLocalizationsPt([String locale = 'pt']) : super(locale);

  @override
  String get updateChecking => 'Procurando atualizações…';

  @override
  String get updateUpToDate => 'Atualizado';

  @override
  String updateUpToDateTooltip(String app, String version) {
    return 'O $app $version é a versão mais recente. Clique para procurar de novo.';
  }

  @override
  String updateAvailable(String version) {
    return 'Atualizar para $version';
  }

  @override
  String updateAvailableTooltip(String app, String version) {
    return 'O $app fecha e o Voges Updater instala a versão $version.';
  }

  @override
  String get updateOpening => 'Abrindo o atualizador…';

  @override
  String updateDownloadAvailable(String version) {
    return 'Versão $version disponível';
  }

  @override
  String get updateDownloadTooltip => 'Baixe a versão nova no site.';

  @override
  String updateMoveToApplications(String app) {
    return 'Para atualizar o $app por aqui, mova-o para a pasta Aplicativos e abra de novo.';
  }

  @override
  String get updateCheckFailed => 'Não foi possível procurar atualizações';

  @override
  String get updateCheckFailedTooltip => 'Clique para tentar de novo.';

  @override
  String get updateLaunchFailed => 'Não foi possível abrir o atualizador.';

  @override
  String get updateDownloadPage => 'Página de download';

  @override
  String get updaterHeading => 'Atualizações dos seus apps Voges';

  @override
  String updaterHostClosed(String app) {
    return 'O $app foi fechado para instalar as atualizações. Ele abre de novo quando você terminar.';
  }

  @override
  String get updaterChecking => 'Procurando atualizações…';

  @override
  String get updaterSelectAll => 'Selecionar todos';

  @override
  String updaterVersionChange(String from, String to) {
    return '$from → $to';
  }

  @override
  String get updaterWhatsNew => 'Novidades';

  @override
  String get updaterForThisUser => 'Para este usuário';

  @override
  String get updaterForAllUsers =>
      'Para todos os usuários · pede permissão de administrador';

  @override
  String get updaterNotNow => 'Agora não';

  @override
  String updaterUpdateButton(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Atualizar $count apps',
      one: 'Atualizar 1 app',
    );
    return '$_temp0';
  }

  @override
  String get updaterAllUpToDate =>
      'Todos os seus apps Voges estão atualizados.';

  @override
  String get updaterOffline =>
      'Não foi possível procurar atualizações. Verifique a internet.';

  @override
  String updaterHostNotFound(String app) {
    return 'O Voges Updater não encontrou onde o $app está instalado. Baixe a versão nova no site.';
  }

  @override
  String get updaterRowCheckFailed => 'Não foi possível procurar atualizações';

  @override
  String get updaterTryAgain => 'Tentar de novo';

  @override
  String get updaterCloseApps =>
      'Salve seu trabalho e feche estes apps. A atualização continua sozinha quando eles fecharem.';

  @override
  String updaterOpenWindows(String app, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count janelas',
      one: '1 janela',
    );
    return '$app · $_temp0';
  }

  @override
  String updaterOtherAccount(String app) {
    return '$app · aberto em outra conta de usuário';
  }

  @override
  String updaterDownloading(int percent) {
    return 'Baixando… $percent%';
  }

  @override
  String get updaterVerifying => 'Conferindo o download…';

  @override
  String get updaterInstalling => 'Instalando…';

  @override
  String get updaterAdminHint =>
      'Confirme o pedido de administrador. Se ele não aparecer, procure na barra de tarefas.';

  @override
  String get updaterPasswordHint => 'Digite sua senha na janela que abriu.';

  @override
  String updaterUpdated(String version) {
    return 'Atualizado para $version';
  }

  @override
  String get updaterCancel => 'Cancelar';

  @override
  String get updaterClose => 'Fechar';

  @override
  String updaterOpenApp(String app) {
    return 'Abrir o $app';
  }

  @override
  String get updaterAlreadyRunning =>
      'O Voges Updater já está aberto em outra janela.';

  @override
  String get updaterErrorNetwork =>
      'O download falhou. Verifique a internet e tente de novo.';

  @override
  String get updaterErrorVerification =>
      'Não foi possível conferir o download, então nada foi instalado. Tente de novo mais tarde.';

  @override
  String updaterErrorUnavailable(String version) {
    return 'A versão $version ainda não está disponível para este sistema.';
  }

  @override
  String updaterErrorPermission(String app) {
    return 'O macOS não permitiu substituir o $app. Instale pelo instalador.';
  }

  @override
  String updaterErrorInUse(String app) {
    return 'O $app ou um dos arquivos dele ainda estava em uso. Feche e tente de novo.';
  }

  @override
  String get updaterErrorDeclined =>
      'A permissão não foi dada, então nada foi instalado.';

  @override
  String get updaterErrorNoPasswordWindow =>
      'Este sistema não consegue mostrar uma janela de senha. Instale a atualização pelo terminal:';

  @override
  String get updaterErrorNotAuthorized =>
      'Sua conta não pode instalar apps. Peça para um administrador executar:';

  @override
  String get updaterErrorPackageManager =>
      'O gerenciador de pacotes não conseguiu instalar a atualização:';

  @override
  String updaterErrorFailed(int code) {
    return 'A atualização falhou (código $code).';
  }

  @override
  String get updaterErrorUnknown => 'A atualização falhou.';

  @override
  String get updaterKeepOpen =>
      'Deixe esta janela aberta até o comando terminar.';

  @override
  String get updaterCopyCommand => 'Copiar comando';

  @override
  String get updaterOpenInstaller => 'Abrir o instalador';

  @override
  String get updaterShowLog => 'Ver registro';
}
