package main

import (
	"fmt"
	"net/http"
	"os"
	"time"
)

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: ssltruster_probe.go URL")
		os.Exit(2)
	}
	client := &http.Client{
		Timeout: 20 * time.Second,
		CheckRedirect: func(request *http.Request, _ []*http.Request) error {
			if request.URL.Scheme != "https" {
				return fmt.Errorf("redirect to a non-HTTPS URL")
			}
			return nil
		},
	}
	request, err := http.NewRequest(http.MethodGet, os.Args[1], nil)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	request.Header.Set("User-Agent", "EAP-SSLTruster/1.0")
	response, err := client.Do(request)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer response.Body.Close()
	fmt.Println(response.StatusCode)
}
