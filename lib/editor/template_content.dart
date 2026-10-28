import 'package:flutter_quill/quill_delta.dart';

import '../l10n/l10n.dart';

/// Sample text of the résumé template, in the user's language.
Delta resumeContent(AppLocalizations l10n) {
  const gray = '#595959';
  return Delta()
    ..insert(l10n.resumeName, {'bold': true, 'size': '24'})
    ..insert('\n', {'align': 'center'})
    ..insert(l10n.resumeContact, {'color': gray})
    ..insert('\n', {'align': 'center'})
    ..insert(l10n.resumeObjective)
    ..insert('\n', {'header': 2})
    ..insert('${l10n.resumeObjectiveText}\n')
    ..insert(l10n.resumeExperience)
    ..insert('\n', {'header': 2})
    ..insert(l10n.resumeRole, {'bold': true})
    ..insert('\n')
    ..insert(l10n.resumePeriod, {'italic': true, 'color': gray})
    ..insert('\n')
    ..insert(l10n.resumeAchievement)
    ..insert('\n', {'list': 'bullet'})
    ..insert(l10n.resumeOtherAchievement)
    ..insert('\n', {'list': 'bullet'})
    ..insert(l10n.resumeEducation)
    ..insert('\n', {'header': 2})
    ..insert(l10n.resumeCourse, {'bold': true})
    ..insert('\n')
    ..insert(l10n.resumeGraduation, {'italic': true, 'color': gray})
    ..insert('\n')
    ..insert(l10n.resumeSkills)
    ..insert('\n', {'header': 2})
    ..insert(l10n.resumeSkill)
    ..insert('\n', {'list': 'bullet'})
    ..insert(l10n.resumeLanguage)
    ..insert('\n', {'list': 'bullet'});
}
