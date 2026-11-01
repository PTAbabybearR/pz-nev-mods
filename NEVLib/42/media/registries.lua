-- NEV Lib item tags: B42 keeps item tags in a registry (zombie.scripting.objects.ItemTag); a mod registers its own
-- here, read before the scripts. Checked in the server self test (armor-tag).
-- nev:metalarmor: every armour add-on, so one library repair recipe covers all cars (PARTS-DESIGN 6.5, U5 5, #174).
ItemTag.register("nev:metalarmor")
-- nev:finearmor: the Fine grade of an armour piece (DESIGN 9.1 revision 17, #215); the item ids end in _Fine too.
ItemTag.register("nev:finearmor")
