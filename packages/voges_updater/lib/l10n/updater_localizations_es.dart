// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'updater_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Spanish Castilian (`es`).
class UpdaterLocalizationsEs extends UpdaterLocalizations {
  UpdaterLocalizationsEs([String locale = 'es']) : super(locale);

  @override
  String get updateChecking => 'Buscando actualizaciones…';

  @override
  String get updateUpToDate => 'Actualizado';

  @override
  String updateUpToDateTooltip(String app, String version) {
    return '$app $version es la versión más reciente. Haz clic para buscar de nuevo.';
  }

  @override
  String updateAvailable(String version) {
    return 'Actualizar a $version';
  }

  @override
  String updateAvailableTooltip(String app, String version) {
    return '$app se cierra y Voges Updater instala la versión $version.';
  }

  @override
  String get updateOpening => 'Abriendo el actualizador…';

  @override
  String updateDownloadAvailable(String version) {
    return 'Versión $version disponible';
  }

  @override
  String get updateDownloadTooltip =>
      'Descarga la nueva versión desde el sitio web.';

  @override
  String updateMoveToApplications(String app) {
    return 'Para actualizar $app desde aquí, muévelo a la carpeta Aplicaciones y vuelve a abrirlo.';
  }

  @override
  String get updateCheckFailed => 'No se pudo buscar actualizaciones';

  @override
  String get updateCheckFailedTooltip => 'Haz clic para intentarlo de nuevo.';

  @override
  String get updateLaunchFailed => 'No se pudo abrir el actualizador.';

  @override
  String get updateDownloadPage => 'Página de descarga';

  @override
  String get updaterHeading => 'Actualizaciones de tus apps de Voges';

  @override
  String updaterHostClosed(String app) {
    return '$app se cerró para instalar las actualizaciones. Se volverá a abrir cuando termines.';
  }

  @override
  String get updaterChecking => 'Buscando actualizaciones…';

  @override
  String get updaterSelectAll => 'Seleccionar todo';

  @override
  String updaterVersionChange(String from, String to) {
    return '$from → $to';
  }

  @override
  String get updaterWhatsNew => 'Novedades';

  @override
  String get updaterForThisUser => 'Para este usuario';

  @override
  String get updaterForAllUsers =>
      'Para todos los usuarios · pide permiso de administrador';

  @override
  String get updaterNotNow => 'Ahora no';

  @override
  String updaterUpdateButton(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Actualizar $count apps',
      one: 'Actualizar 1 app',
    );
    return '$_temp0';
  }

  @override
  String get updaterAllUpToDate =>
      'Todas tus apps de Voges están actualizadas.';

  @override
  String get updaterOffline =>
      'No se pudo buscar actualizaciones. Revisa tu conexión a internet.';

  @override
  String updaterHostNotFound(String app) {
    return 'Voges Updater no encontró dónde está instalado $app. Descarga la nueva versión desde el sitio web.';
  }

  @override
  String get updaterRowCheckFailed => 'No se pudo buscar actualizaciones';

  @override
  String get updaterTryAgain => 'Intentar de nuevo';

  @override
  String get updaterCloseApps =>
      'Guarda tu trabajo y cierra estas apps. La actualización continúa sola cuando se cierren.';

  @override
  String updaterOpenWindows(String app, int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count ventanas',
      one: '1 ventana',
    );
    return '$app · $_temp0';
  }

  @override
  String updaterOtherAccount(String app) {
    return '$app · en uso en otra cuenta de usuario';
  }

  @override
  String updaterDownloading(int percent) {
    return 'Descargando… $percent%';
  }

  @override
  String get updaterVerifying => 'Comprobando la descarga…';

  @override
  String get updaterInstalling => 'Instalando…';

  @override
  String get updaterAdminHint =>
      'Confirma la solicitud de administrador. Si no la ves, búscala en la barra de tareas.';

  @override
  String get updaterPasswordHint =>
      'Escribe tu contraseña en la ventana que se abrió.';

  @override
  String updaterUpdated(String version) {
    return 'Actualizado a $version';
  }

  @override
  String get updaterCancel => 'Cancelar';

  @override
  String get updaterClose => 'Cerrar';

  @override
  String updaterOpenApp(String app) {
    return 'Abrir $app';
  }

  @override
  String updaterStartFailed(String app) {
    return 'Voges Updater no pudo iniciarse. Descarga la nueva versión de $app desde el sitio web.';
  }

  @override
  String get updaterAlreadyRunning =>
      'Voges Updater ya está abierto en otra ventana.';

  @override
  String get updaterErrorNetwork =>
      'La descarga falló. Revisa tu conexión a internet e inténtalo de nuevo.';

  @override
  String get updaterErrorVerification =>
      'No se pudo verificar la descarga, así que no se instaló nada. Inténtalo de nuevo más tarde.';

  @override
  String updaterErrorUnavailable(String version) {
    return 'La versión $version todavía no está disponible para este sistema.';
  }

  @override
  String updaterErrorPermission(String app) {
    return 'macOS no permitió reemplazar $app. Instálalo con el instalador.';
  }

  @override
  String updaterErrorInUse(String app) {
    return '$app o uno de sus archivos todavía estaba en uso. Ciérralo e inténtalo de nuevo.';
  }

  @override
  String get updaterErrorDeclined =>
      'No se dio el permiso, así que no se instaló nada.';

  @override
  String get updaterErrorNoPasswordWindow =>
      'Este sistema no puede mostrar una ventana de contraseña. Instala la actualización desde una terminal:';

  @override
  String get updaterErrorNotAuthorized =>
      'Tu cuenta no puede instalar apps. Pide a un administrador que ejecute:';

  @override
  String get updaterErrorPackageManager =>
      'El gestor de paquetes no pudo instalar la actualización:';

  @override
  String updaterErrorFailed(int code) {
    return 'La actualización falló (código $code).';
  }

  @override
  String get updaterErrorUnknown => 'La actualización falló.';

  @override
  String get updaterKeepOpen =>
      'Deja esta ventana abierta hasta que termine el comando.';

  @override
  String get updaterCopyCommand => 'Copiar comando';

  @override
  String get updaterOpenInstaller => 'Abrir el instalador';

  @override
  String get updaterShowLog => 'Ver registro';
}
