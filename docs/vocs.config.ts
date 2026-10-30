import { defineConfig } from "vocs";

export default defineConfig({
  rootDir: ".",
  title: "CoW Silo",
  description: "Competitive onchain fee conversion through CoW Protocol solvers.",
  sidebar: [
    {
      text: "Understand Silo",
      items: [
        { text: "Overview", link: "/" },
        { text: "How it works", link: "/how-it-works" },
        { text: "Contracts", link: "/contracts" },
        { text: "Security model", link: "/security" },
        { text: "TJAR comparison", link: "/tjar-comparison" },
      ],
    },
    {
      text: "Actors",
      items: [
        { text: "Protocols", link: "/actors/protocols" },
        { text: "Solvers", link: "/actors/solvers" },
        { text: "Deployers", link: "/actors/deployers" },
      ],
    },
    {
      text: "Developers",
      items: [
        { text: "SDK", link: "/developers/sdk" },
        { text: "Offline testing", link: "/developers/offline-testing" },
        { text: "Deployments", link: "/deployments" },
        { text: "Roadmap", link: "/roadmap" },
      ],
    },
  ],
  topNav: [
    { text: "Guide", link: "/" },
    { text: "GitHub", link: "https://github.com/bleu/cow-silo" },
  ],
});
