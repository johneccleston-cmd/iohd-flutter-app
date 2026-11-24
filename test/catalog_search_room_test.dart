// The job and estimate pages' "Add a line" search (audit 2026-11-24): with the box at the bottom of a 1366 x 768 window,
// the page could scroll it up only to the page's end, and the results were cut to about three rows. CatalogSearchRoom
// at the end of the page gives the page room while a search has the keyboard, and goes when it leaves.
//   flutter test test/catalog_search_room_test.dart

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'job_page_fixture.dart';

void main() {
  setUpAll(jobPageSetUp);

  for (final (id, edit) in const [(kJobId, 'Edit Job'), (kEstimateId, 'Edit Estimate')]) {
    testWidgets('$edit: "Add a line" at the window\'s bottom opens its results in full, then the room goes', (t) async {
      final s = FakeJobServer();
      await pumpJobPage(t, s, id: id, size: const Size(1366, 768), body: () async {
        await t.tap(find.text(edit));
        await settle(t, frames: 6);
        // The box at the very bottom of the window, as after scrolling down to it.
        await Scrollable.ensureVisible(t.element(catalogSearch), alignment: 1.0);
        await settle(t, frames: 4);
        await t.tap(catalogSearch);
        await t.enterText(catalogSearch, 'spring');
        await settle(t, frames: 8);
        final box = t.getRect(catalogSearch);
        final list = [
          for (final e in find.byType(ListView).evaluate())
            if (t.getRect(find.byWidget(e.widget)).top >= box.bottom - 1) t.getRect(find.byWidget(e.widget)),
        ].single;
        expect(box.bottom, lessThan(768 - 400), reason: 'the page scrolled the box up to make room');
        expect(list.bottom, lessThan(768 - 4), reason: 'the list ends where its results end, not at the window\'s edge');

        // The keyboard leaves the search: nothing on screen moves (taking the room away at once slid the page down
        // 383 px in Chrome)...
        final room = find.byKey(const ValueKey('catalog-search-room'));
        expect(t.getSize(room).height, 460);
        FocusManager.instance.primaryFocus?.unfocus();
        await settle(t, frames: 6);
        expect(t.getRect(catalogSearch), box, reason: 'the page did not move');
        expect(t.getSize(room).height, lessThan(460), reason: 'the part below the window went at once');
        // ...and the rest goes as the page is scrolled up past it.
        Scrollable.of(t.element(catalogSearch)).position.jumpTo(0);
        await settle(t, frames: 4);
        expect(t.getSize(room).height, 0);
      });
    });
  }
}
