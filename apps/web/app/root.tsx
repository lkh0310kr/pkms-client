import type { LinksFunction, MetaFunction } from "react-router";
import { Links, Meta, Outlet, Scripts, ScrollRestoration } from "react-router";
import styles from "./styles.css?url";

export const links: LinksFunction = () => [{ rel: "stylesheet", href: styles }];
export const meta: MetaFunction = () => [
  { title: "PKMS — your Markdown workspace" },
  { name: "description", content: "A fast, collaborative Markdown vault backed by your GitHub repository." },
];

export function Layout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head><meta charSet="utf-8" /><meta name="viewport" content="width=device-width, initial-scale=1" /><Meta /><Links /></head>
      <body>{children}<ScrollRestoration /><Scripts /></body>
    </html>
  );
}

export default function App() {
  return <Outlet />;
}
