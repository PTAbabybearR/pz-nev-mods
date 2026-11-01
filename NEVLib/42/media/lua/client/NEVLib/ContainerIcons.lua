-- NEV Lib: the in-car fridge's button in the loot window shows a chest freezer (#197). ISInventoryPage:addContainerButton
-- picks the button picture by container type from ContainerButtonIcons (shared/Definitions/ContainerButtonIcons.lua)
-- and falls back to the plain container; a vehicle part's container type is its part id, NEVFridge for every NEV.
-- The vanilla chest-freezer icon (user 10-16: borrow vanilla's freezer; the upright fridge is too small to read at
-- button size). Vanilla's ice-cream freezers use it too (ContainerButtonIcons.icecream).
require "Definitions/ContainerButtonIcons"

ContainerButtonIcons = ContainerButtonIcons or {}
ContainerButtonIcons.NEVFridge = getTexture("media/ui/Container_Freezer.png")
-- The 5th seat (rear middle, NEVSeatRearMiddle) is our own part id, so vanilla's table has no entry and the button fell
-- back to the plain box; give it vanilla's car-seat picture like SeatFrontLeft..SeatRearRight (ContainerButtonIcons
-- t.seat). #250
ContainerButtonIcons.NEVSeatRearMiddle = getTexture("media/ui/Container_Carseat.png")
-- The frunk (NEVFrunk, #306) is a second trunk: vanilla's trunk picture (ContainerButtonIcons t.trunk, TruckBed).
ContainerButtonIcons.NEVFrunk = getTexture("media/ui/Container_TruckBed.png")
