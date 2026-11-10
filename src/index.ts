import { AppWrapperRoute, defineWebApplication } from "@opencloud-eu/web-pkg";
import { useGettext } from "vue3-gettext";
import translations from "../l10n/translations.json";
import OfficeViewer from "./App.vue";

// Must be unique within all installed apps of an OpenCloud instance.
const applicationId = "office-viewer";

export default defineWebApplication({
  setup() {
    const { $gettext } = useGettext();

    const routes = [
      {
        name: applicationId,
        path: "/:driveAliasAndItem(.*)?",
        component: AppWrapperRoute(OfficeViewer, {
          applicationId,
          // @silurus/ooxml fetches the file itself from the (signed) URL, so inline is fine.
          urlForResourceOptions: { disposition: "inline" },
        }),
        meta: {
          authContext: "hybrid",
          title: $gettext("office-viewer"),
          patchCleanPath: true,
        },
      },
    ];

    const appInfo = {
      name: $gettext("office-viewer"),
      id: applicationId,
      icon: "file-text",
      extensions: [
        // OOXML — rendered by @silurus/ooxml
        { extension: "docx", routeName: applicationId },
        { extension: "xlsx", routeName: applicationId },
        { extension: "pptx", routeName: applicationId },
        // Legacy binary Office — rendered via @silurus/ooxml-legacy-office
        { extension: "doc", routeName: applicationId },
        { extension: "xls", routeName: applicationId },
        { extension: "ppt", routeName: applicationId },
        // ODF — registered so these files route here, but @silurus/ooxml has no ODF
        // renderer yet. App.vue shows a "download instead" fallback for them.
        { extension: "odt", routeName: applicationId },
        { extension: "ods", routeName: applicationId },
        { extension: "odp", routeName: applicationId },
      ],
    };

    return {
      appInfo,
      routes,
      translations,
    };
  },
});
