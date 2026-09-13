import localUnitTest from './LocalUnit.test';
import aiImportLocalUnitTest from './AiImportLocalUnit.test';

export default function testsuite() {
  localUnitTest();
  aiImportLocalUnitTest();
}
