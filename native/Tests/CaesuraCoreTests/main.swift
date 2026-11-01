import Foundation
import CaesuraCore

// Entry point: registers every suite, then runs all tests.

BreaksPlannerTests.registerAll()
SchedulerTests.registerAll()
SettingsStoreTests.registerAll()
CommandTests.registerAll()
UtilsTests.registerAll()
UntilMorningTests.registerAll()
IdeasTests.registerAll()
PoemsTests.registerAll()
PoemBreakTests.registerAll()
PoemRevealTests.registerAll()
SanitizerTests.registerAll()
StatusMessagesTests.registerAll()
LocalizationTests.registerAll()
PauseCauseTests.registerAll()
TrayIconTests.registerAll()
PlaybackNamesTests.registerAll()
VersionCheckTests.registerAll()
CliIpcTests.registerAll()
RegressionTests.registerAll()
TrialProfileTests.registerAll()

exit(TestRunner.runAll())
