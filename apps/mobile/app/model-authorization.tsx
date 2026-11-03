import { useRouter } from "expo-router";
import { useEffect } from "react";

export default function ModelAuthorizationReturn() {
  const router = useRouter();
  useEffect(() => {
    if (router.canGoBack()) router.back();
    else router.replace("/(settings)/models");
  }, [router]);
  return null;
}
