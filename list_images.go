package main

import (
        "fmt"
        "github.com/fsouza/go-dockerclient"
	"os"
	"path"
)

func main() {
        // get client from ENV like https://github.com/md5/go-dockerclient/compare/new-client-from-env
	endpoint := os.Getenv("DOCKER_HOST")
	//tlsVerify := os.Getenv("DOCKER_TLS_VERIFY")
	certPath := os.Getenv("DOCKER_CERT_PATH")

	cert := path.Join(certPath, "cert.pem")
	key := path.Join(certPath, "key.pem")
	ca := path.Join(certPath, "ca.pem")

        client, _ := docker.NewTLSClient(endpoint, cert, key, ca)
        imgs, _ := client.ListImages(docker.ListImagesOptions{All: true})
        for _, img := range imgs {
                fmt.Println("ID: ", img.ID)
                fmt.Println("RepoTags: ", img.RepoTags)
                fmt.Println("Created: ", img.Created)
                fmt.Println("Size: ", img.Size)
                fmt.Println("VirtualSize: ", img.VirtualSize)
                fmt.Println("ParentId: ", img.ParentID)
        }

	fmt.Println("hello")
}
